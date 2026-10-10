import Foundation

public struct DiagnosticCommand: Equatable, Sendable, CustomStringConvertible {
	public let arguments: [String]

	public init(_ arguments: String...) {
		self.arguments = arguments
	}

	public var description: String {
		arguments.map { $0.contains(" ") || $0.isEmpty ? "'\($0)'" : $0 }.joined(separator: " ")
	}
}

public struct DiagnosticRun: Equatable, Sendable {
	public let status: Int32?
	public let output: String
	public let failure: String?

	public init(status: Int32?, output: String, failure: String? = nil) {
		self.status = status
		self.output = output
		self.failure = failure
	}
}

public struct DiagnosisStep: Sendable {
	public let command: DiagnosticCommand
	public let title: String
	let keeps: @Sendable (String) -> Bool
	let followUps: @Sendable (String) -> [DiagnosticCommand]

	public init(_ command: DiagnosticCommand, title: String? = nil, keeping keeps: @escaping @Sendable (String) -> Bool = { _ in true }, then followUps: @escaping @Sendable (String) -> [DiagnosticCommand] = { _ in [] }) {
		self.command = command
		self.title = title ?? command.description
		self.keeps = keeps
		self.followUps = followUps
	}
}

public enum GuestDiagnosis {
	public static let outputPrefix = "| "
	public static let headerPrefix = "== "

	static let sysctlTopics = ["fsync", "flush", "barrier", "apfs", "jnl", "journal", "sync", "cache", "virtio", "vmm", "hv_", "hypervisor", "osversion", "osproductversion", "hw.model", "boottime"]

	static let networkLogPredicate = #"process == "configd" OR subsystem == "com.apple.IPConfiguration" OR subsystem == "com.apple.SystemConfiguration" OR (process == "kernel" AND (eventMessage CONTAINS[c] "en0" OR eventMessage CONTAINS[c] "virtio" OR eventMessage CONTAINS[c] "network"))"#
	static let dhcpHistoryPredicate = #"subsystem == "com.apple.IPConfiguration" AND (eventMessage BEGINSWITH "DHCP en0" OR eventMessage CONTAINS "en0 link")"#
	static let storageLogPredicate = #"process == "kernel" AND (eventMessage CONTAINS[c] "virtio" OR eventMessage CONTAINS[c] "flush" OR eventMessage CONTAINS[c] "barrier" OR eventMessage CONTAINS[c] "cache" OR eventMessage CONTAINS[c] "apfs" OR eventMessage CONTAINS[c] "disk")"#

	public static let steps: [DiagnosisStep] = [
		DiagnosisStep(DiagnosticCommand("/usr/bin/sw_vers")),
		DiagnosisStep(DiagnosticCommand("/bin/date", "-u")),
		DiagnosisStep(DiagnosticCommand("/usr/bin/uptime")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/ioreg", "-w0", "-p", "IOService")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/ioreg", "-l", "-w0", "-t", "-r", "-c", "IOBlockStorageDevice")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/ioreg", "-l", "-w0", "-r", "-c", "IOMedia")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/ioreg", "-l", "-w0", "-r", "-c", "IOPCIDevice")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/diskutil", "list")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/diskutil", "list", "physical"), then: { output in
			physicalDisks(in: output).map { DiagnosticCommand("/usr/sbin/diskutil", "info", $0) }
		}),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/diskutil", "apfs", "list")),
		DiagnosisStep(DiagnosticCommand("/sbin/mount")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/sysctl", "-a"), title: "sysctl -a, only names containing \(sysctlTopics.joined(separator: ", "))", keeping: namesTopic),
		DiagnosisStep(DiagnosticCommand("/sbin/ifconfig", "-a")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/networksetup", "-listallhardwareports")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/networksetup", "-listnetworkserviceorder")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/networksetup", "-listallnetworkservices"), then: { output in
			networkServices(in: output).map { DiagnosticCommand("/usr/sbin/networksetup", "-getinfo", $0) }
		}),
		DiagnosisStep(DiagnosticCommand("/sbin/ifconfig", "-l"), then: { output in
			ethernetInterfaces(in: output).flatMap { [DiagnosticCommand("/usr/sbin/ipconfig", "getpacket", $0), DiagnosticCommand("/usr/sbin/ipconfig", "getsummary", $0)] }
		}),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/scutil", "--nwi")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/netstat", "-rn", "-f", "inet")),
		DiagnosisStep(DiagnosticCommand("/usr/sbin/arp", "-an")),
		DiagnosisStep(DiagnosticCommand("/usr/bin/plutil", "-p", "/Library/Preferences/SystemConfiguration/preferences.plist")),
		DiagnosisStep(DiagnosticCommand("/usr/bin/plutil", "-p", "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist")),
		DiagnosisStep(DiagnosticCommand("/usr/bin/log", "show", "--last", "10m", "--info", "--style", "compact", "--predicate", networkLogPredicate)),
		DiagnosisStep(DiagnosticCommand("/usr/bin/log", "show", "--last", "10m", "--info", "--style", "compact", "--predicate", storageLogPredicate)),
		DiagnosisStep(DiagnosticCommand("/usr/bin/log", "show", "--last", "48h", "--style", "compact", "--predicate", dhcpHistoryPredicate)),
	]

	public static func run(_ steps: [DiagnosisStep] = steps, executing execute: (DiagnosticCommand) -> DiagnosticRun, emit: ([String]) -> Void) {
		for step in steps {
			let run = execute(step.command)
			emit(shown(run, titled: step.title, keeping: step.keeps))
			for command in step.followUps(run.output) {
				emit(shown(execute(command), titled: command.description, keeping: { _ in true }))
			}
		}
	}

	private static func shown(_ run: DiagnosticRun, titled title: String, keeping keeps: (String) -> Bool) -> [String] {
		let outcome = run.failure.map { "could not run: \($0)" } ?? run.status.map { "exit \($0)" } ?? "no exit status"
		var lines = run.output.split(separator: "\n", omittingEmptySubsequences: false)
		if lines.last?.isEmpty == true {
			lines.removeLast()
		}
		return [headerPrefix + title + " (\(outcome))"] + lines.filter { keeps(String($0)) }.map { outputPrefix + $0 }
	}

	static func namesTopic(_ line: String) -> Bool {
		let name = line.prefix { $0 != ":" && $0 != "=" }.lowercased()
		return sysctlTopics.contains { name.contains($0) }
	}

	static func physicalDisks(in listing: String) -> [String] {
		listing.split(separator: "\n").compactMap { line in
			guard line.hasPrefix("/dev/disk") else { return nil }
			return line.split(separator: " ").first.map(String.init)
		}
	}

	static func networkServices(in listing: String) -> [String] {
		listing.split(separator: "\n").filter { !$0.hasPrefix("An asterisk") }.map { line in
			String(line.hasPrefix("*") ? line.dropFirst() : line)
		}.filter { !$0.isEmpty }
	}

	static func ethernetInterfaces(in listing: String) -> [String] {
		listing.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0.hasPrefix("en") }
	}
}
