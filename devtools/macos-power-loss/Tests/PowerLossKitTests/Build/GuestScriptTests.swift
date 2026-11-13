import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(5)))
struct GuestScriptTests {
	private let guest = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../guest").standardized
	private let label = "dev.hloth.devtools.native-note-power-loss-test"
	private let launcher = "/usr/local/libexec/native-note-power-loss/start-agent.sh"

	private func run(_ script: String, in folder: URL? = nil, _ arguments: [String], tools: URL? = nil, environment: [String: String] = [:]) throws -> (status: Int32, errors: [String]) {
		let errors = Pipe()
		let process = Process()
		process.executableURL = URL(filePath: "/bin/sh")
		process.arguments = [(folder ?? guest).appending(path: script).path] + arguments
		process.environment = environment.merging(["PATH": [tools?.path, "/usr/bin:/bin:/usr/sbin:/sbin"].compactMap(\.self).joined(separator: ":")]) { $1 }
		process.standardOutput = FileHandle.nullDevice
		process.standardError = errors
		try process.run()
		let printed = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		process.waitUntilExit()
		return (process.terminationStatus, printed.split(separator: "\n").map(String.init))
	}

	@Test func theLaunchDaemonRunsTheLauncherSetupInstallsAndLogsWhereSetupPoints() throws {
		let plist = try Data(contentsOf: guest.appending(path: "\(label).plist"))
		let daemon = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])

		#expect(daemon["Label"] as? String == label)
		#expect(daemon["ProgramArguments"] as? [String] == ["/bin/sh", launcher])
		#expect(daemon["StandardOutPath"] as? String == AgentLog.path)
		#expect(daemon["StandardErrorPath"] as? String == AgentLog.path)
		let setup = try String(contentsOf: guest.appending(path: "setup.sh"), encoding: .utf8)
		#expect(setup.contains("launcher=\(launcher)\n"))
		#expect(setup.contains("label=\(label)\n"))
	}

	@Test(arguments: [false, true]) func startingTheAgentClearsItsLogBeforeLaunchdStartsIt(alreadyLoaded: Bool) throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let tools = directory.appending(path: "tools")
		try stub("launchctl", in: tools, #"echo "$* $(wc -c <"$LOG" | tr -d ' ')" >>"$CALLS"; [ "$1" != bootstrap ] || [ -z "$LOADED" ]"#)
		let launcher = directory.appending(path: "libexec/start-agent.sh")
		let daemon = directory.appending(path: "LaunchDaemons/\(label).plist")
		let log = directory.appending(path: "agent.log")
		let calls = directory.appending(path: "calls")
		try FileManager.default.createDirectory(at: daemon.deletingLastPathComponent(), withIntermediateDirectories: true)
		try Data(String(repeating: "power-loss-agent: no executable path\n", count: 3).utf8).write(to: log)

		let (status, _) = try run("install-agent.sh", [launcher.path, daemon.path, log.path], tools: tools, environment: ["LOG": log.path, "CALLS": calls.path, "LOADED": alreadyLoaded ? "yes" : ""])

		#expect(status == 0)
		let bootstrap = "bootstrap system \(daemon.path) 0\n"
		let kickstart = "kickstart -k system/\(label) 0\n"
		#expect(try String(contentsOf: calls, encoding: .utf8) == (alreadyLoaded ? bootstrap + kickstart : bootstrap))
		#expect(try Data(contentsOf: log).isEmpty)
		#expect(try Data(contentsOf: launcher) == Data(contentsOf: guest.appending(path: "start-agent.sh")))
		#expect(try FileManager.default.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? Int == 0o755)
		#expect(try Data(contentsOf: daemon) == Data(contentsOf: guest.appending(path: "\(label).plist")))
	}

	@Test(arguments: [0, 3]) func theLauncherLogsOnlyTheFirstFailedMountWithItsTime(failures: Int) throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let tools = directory.appending(path: "tools")
		try stub("mkdir", in: tools, ":")
		try stub("sleep", in: tools, ":")
		try stub("mount", in: tools, #"[ ! -e "$MOUNTED" ] || echo "power-loss-kit on /private/var/native-note-power-loss/kit (virtiofs, local)""#)
		try stub("mount_virtiofs", in: tools, #"""
			attempt=$(($(cat "$ATTEMPTS" 2>/dev/null || echo 0) + 1))
			echo "$attempt" >"$ATTEMPTS"
			[ "$attempt" -gt "$FAILURES" ] || { echo "mount_virtiofs: Unable to mount: No such device" >&2; exit 1; }
			touch "$MOUNTED"
			"""#)
		let attempts = directory.appending(path: "attempts")
		let started = Date.now

		let (_, errors) = try run("start-agent.sh", [], tools: tools, environment: ["ATTEMPTS": attempts.path, "MOUNTED": directory.appending(path: "mounted").path, "FAILURES": "\(failures)"])

		#expect(try String(contentsOf: attempts, encoding: .utf8) == "\(failures + 1)\n")
		let reports = errors.filter { $0.hasPrefix("start-agent: ") }.map { $0.dropFirst("start-agent: ".count) }
		#expect(reports.map { $0.dropFirst(21) } == (failures == 0 ? [] : ["cannot mount the kit, retrying every second: mount_virtiofs: Unable to mount: No such device"]))
		for report in reports {
			let time = try Date(String(report.prefix(20)), strategy: .iso8601)
			#expect(time >= started.addingTimeInterval(-1) && time <= .now)
		}
		#expect(errors.last?.contains("/private/var/native-note-power-loss/kit/power-loss-agent") == true)
	}

	@Test func theLauncherGivesUpAfterPacedAttemptsWhenTheKitNeverShowsAsMounted() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let tools = directory.appending(path: "tools")
		try stub("mkdir", in: tools, ":")
		try stub("mount", in: tools, "echo \"/dev/disk3s1 on / (apfs, local)\"")
		try stub("sleep", in: tools, #"echo "$1" >>"$SLEEPS""#)
		try stub("mount_virtiofs", in: tools, #"echo mounted >>"$ATTEMPTS""#)
		let attempts = directory.appending(path: "attempts")
		let sleeps = directory.appending(path: "sleeps")

		let (status, errors) = try run("start-agent.sh", [], tools: tools, environment: ["ATTEMPTS": attempts.path, "SLEEPS": sleeps.path])

		#expect(status == 1)
		#expect(try String(contentsOf: attempts, encoding: .utf8) == String(repeating: "mounted\n", count: 30))
		#expect(try String(contentsOf: sleeps, encoding: .utf8) == String(repeating: "1\n", count: 29))
		#expect(errors.count == 1)
		#expect(errors.last?.hasSuffix("the kit is not mounted after 30 attempts, giving up") == true)
	}

	private func setUp(in directory: URL, virtualMachine: Bool, libraryMedia: String) throws -> (status: Int32, errors: [String], diskutilCalls: [String]) {
		let kit = directory.appending(path: "kit")
		let tools = directory.appending(path: "tools")
		try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: true)
		try FileManager.default.copyItem(at: guest.appending(path: "setup.sh"), to: kit.appending(path: "setup.sh"))
		try stub("NativeNoteTypist", in: kit, "exit 2")
		try stub("sysctl", in: tools, #"[ "$*" = "-n kern.hv_vmm_present" ] && echo "$VIRTUAL""#)
		try stub("id", in: tools, "echo 0")
		try stub("fdesetup", in: tools, "echo \"FileVault is Off.\"")
		try stub("diskutil", in: tools, #"""
			echo "$*" >>"$CALLS"
			property() { echo "<plist version=\"1.0\"><dict><key>TotalSize</key><integer>$1</integer><key>MediaName</key><string>$2</string></dict></plist>"; }
			case "$*" in
			"list physical") printf '/dev/disk0 (internal, physical):\n   0: GUID_partition_scheme\n/dev/disk4 (internal, physical):\n' ;;
			"info -plist /dev/disk0") property 51539607552 "Apple Inc. VirtIO Block Media" ;;
			"info -plist /dev/disk4") property 2147483648 "$LIBRARY_MEDIA" ;;
			*) exit 1 ;;
			esac
			"""#)
		let calls = directory.appending(path: "calls")
		let environment = ["CALLS": calls.path, "VIRTUAL": virtualMachine ? "1" : "0", "LIBRARY_MEDIA": libraryMedia]

		let (status, errors) = try run("setup.sh", in: kit, [], tools: tools, environment: environment)

		let diskutilCalls = (try? String(contentsOf: calls, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
		return (status, errors, diskutilCalls)
	}

	@Test func setupErasesNothingOutsideAVirtualMachine() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let (status, errors, diskutilCalls) = try setUp(in: directory, virtualMachine: false, libraryMedia: "Apple Inc. VirtIO Block Media")

		#expect(status == 1)
		#expect(errors == ["setup: this erases a disk and runs only inside the power-loss VM; this Mac is not a virtual machine"])
		#expect(diskutilCalls.isEmpty)
	}

	@Test(arguments: ["Virtual Disk", "SanDisk Cruzer"]) func setupRefusesToEraseA2GiBDiskThatIsNotTheVirtualOne(media: String) throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let (status, errors, diskutilCalls) = try setUp(in: directory, virtualMachine: true, libraryMedia: media)

		#expect(status == 1)
		#expect(errors == ["setup: /dev/disk4 is \"\(media)\", not an \"Apple Inc. VirtIO Block Media\" disk; refusing to erase it"])
		#expect(!diskutilCalls.contains { $0.hasPrefix("eraseDisk") })
	}

	@Test func setupErasesTheVirtual2GiBDiskInsideAVirtualMachine() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		let (status, _, diskutilCalls) = try setUp(in: directory, virtualMachine: true, libraryMedia: "Apple Inc. VirtIO Block Media")

		#expect(status == 1)
		#expect(diskutilCalls.last == "eraseDisk APFS PowerLossLibrary GPT /dev/disk4")
	}
}
