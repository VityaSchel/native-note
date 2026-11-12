import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct GuestScriptTests {
	private let guest = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../guest").standardized
	private let label = "dev.hloth.devtools.native-note-power-loss-test"
	private let launcher = "/usr/local/libexec/native-note-power-loss/start-agent.sh"

	private func run(_ script: String, _ arguments: [String], tools: URL? = nil, environment: [String: String] = [:]) throws -> (status: Int32, errors: [String]) {
		let errors = Pipe()
		let process = Process()
		process.executableURL = URL(filePath: "/bin/sh")
		process.arguments = [guest.appending(path: script).path] + arguments
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
}
