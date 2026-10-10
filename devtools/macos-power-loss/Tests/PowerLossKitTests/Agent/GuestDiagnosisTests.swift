import Foundation
import Testing

@testable import PowerLossKit

struct GuestDiagnosisTests {
	private func diagnose(_ steps: [DiagnosisStep], answers: [String: DiagnosticRun]) -> (lines: [String], ran: [String]) {
		var lines: [String] = []
		var ran: [String] = []
		GuestDiagnosis.run(steps, executing: { command in
			ran.append(command.description)
			return answers[command.description] ?? DiagnosticRun(status: 0, output: "")
		}, emit: { lines.append(contentsOf: $0) })
		return (lines, ran)
	}

	@Test func everyCommandIsHeadedByItsOutcomeAndItsOutputIsMarked() {
		let steps = [
			DiagnosisStep(DiagnosticCommand("/usr/bin/sw_vers")),
			DiagnosisStep(DiagnosticCommand("/sbin/mount")),
			DiagnosisStep(DiagnosticCommand("/usr/bin/missing")),
		]

		let (lines, _) = diagnose(steps, answers: [
			"/usr/bin/sw_vers": DiagnosticRun(status: 0, output: "ProductVersion: 27.0\n\nexit 3\nok\n"),
			"/sbin/mount": DiagnosticRun(status: 1, output: ""),
			"/usr/bin/missing": DiagnosticRun(status: nil, output: "", failure: "no such file"),
		])

		#expect(lines == [
			"== /usr/bin/sw_vers (exit 0)",
			"| ProductVersion: 27.0",
			"| ",
			"| exit 3",
			"| ok",
			"== /sbin/mount (exit 1)",
			"== /usr/bin/missing (could not run: no such file)",
		])
		#expect(lines.allSatisfy { if case .output = AgentReply(line: $0) { true } else { false } })
	}

	@Test func eachCommandArrivesAsOneBatchSoTheAgentWritesItOnce() {
		let steps = [
			DiagnosisStep(DiagnosticCommand("/bin/ls"), then: { _ in [DiagnosticCommand("/bin/cat", "a")] }),
			DiagnosisStep(DiagnosticCommand("/bin/pwd")),
		]
		var batches: [[String]] = []

		GuestDiagnosis.run(steps, executing: { _ in DiagnosticRun(status: 0, output: "one\ntwo\n") }, emit: { batches.append($0) })

		#expect(batches == [
			["== /bin/ls (exit 0)", "| one", "| two"],
			["== /bin/cat a (exit 0)", "| one", "| two"],
			["== /bin/pwd (exit 0)", "| one", "| two"],
		])
	}

	@Test func aListingRunsItsFollowUpsRightAfterIt() {
		let steps = [
			DiagnosisStep(DiagnosticCommand("/bin/ls"), then: { output in output.split(separator: "\n").map { DiagnosticCommand("/bin/cat", String($0)) } }),
			DiagnosisStep(DiagnosticCommand("/bin/pwd")),
		]

		let (lines, ran) = diagnose(steps, answers: [
			"/bin/ls": DiagnosticRun(status: 0, output: "a b\nc\n"),
			"/bin/cat c": DiagnosticRun(status: 0, output: "see"),
		])

		#expect(ran == ["/bin/ls", "/bin/cat 'a b'", "/bin/cat c", "/bin/pwd"])
		#expect(lines == ["== /bin/ls (exit 0)", "| a b", "| c", "== /bin/cat 'a b' (exit 0)", "== /bin/cat c (exit 0)", "| see", "== /bin/pwd (exit 0)"])
	}

	@Test func aFilteredStepShowsOnlyTheLinesItKeepsUnderItsTitle() {
		let steps = [DiagnosisStep(DiagnosticCommand("/usr/sbin/sysctl", "-a"), title: "sysctl, some", keeping: GuestDiagnosis.namesTopic)]

		let (lines, _) = diagnose(steps, answers: [
			"/usr/sbin/sysctl -a": DiagnosticRun(status: 0, output: "kern.hv_vmm_present: 1\nkern.maxproc: 4000\nvfs.generic.sync_timeout: 60\nhw.model: VirtualMac2,1\nkern.version: apfs inside\n"),
		])

		#expect(lines == ["== sysctl, some (exit 0)", "| kern.hv_vmm_present: 1", "| vfs.generic.sync_timeout: 60", "| hw.model: VirtualMac2,1"])
	}

	@Test func physicalDisksAreTheWholeDisksDiskutilLists() {
		let listing = """
			/dev/disk0 (internal, physical):
			   #:                       TYPE NAME                    SIZE       IDENTIFIER
			   0:      GUID_partition_scheme                        *51.5 GB    disk0

			/dev/disk4 (external, physical):
			   0:      GUID_partition_scheme                        *2.1 GB     disk4
			"""

		#expect(GuestDiagnosis.physicalDisks(in: listing) == ["/dev/disk0", "/dev/disk4"])
	}

	@Test func everyNetworkServiceIsNamedIncludingDisabledOnes() {
		let listing = """
			An asterisk (*) denotes that a network service is disabled.
			Ethernet
			*Thunderbolt Bridge
			USB 10/100/1000 LAN
			"""

		#expect(GuestDiagnosis.networkServices(in: listing) == ["Ethernet", "Thunderbolt Bridge", "USB 10/100/1000 LAN"])
	}

	@Test func onlyEthernetInterfacesGetTheirDHCPPacketAndSummary() {
		#expect(GuestDiagnosis.ethernetInterfaces(in: "lo0 gif0 stf0 anpi0 en0 en1 utun0 bridge0\n") == ["en0", "en1"])
	}

	@Test func theFixedListCoversStorageAndNetworkWithToolsThatExist() {
		let commands = GuestDiagnosis.steps.map(\.command.description)

		for wanted in [
			"/usr/sbin/ioreg -l -w0 -t -r -c IOBlockStorageDevice",
			"/usr/sbin/ioreg -l -w0 -r -c IOMedia",
			"/usr/sbin/diskutil list physical",
			"/sbin/mount",
			"/sbin/ifconfig -a",
			"/usr/sbin/networksetup -listallhardwareports",
			"/usr/sbin/networksetup -listallnetworkservices",
			"/usr/sbin/scutil --nwi",
		] {
			#expect(commands.contains(wanted), "\(wanted)")
		}
		#expect(commands.contains { $0.hasPrefix("/usr/bin/log show --last 10m") && $0.contains("com.apple.IPConfiguration") })
		for step in GuestDiagnosis.steps {
			let executable = step.command.arguments[0]
			#expect(FileManager.default.isExecutableFile(atPath: executable), "\(executable)")
		}
	}

	@Test func aCommandWithSpacesIsShownQuoted() {
		#expect(DiagnosticCommand("/usr/sbin/networksetup", "-getinfo", "Thunderbolt Bridge").description == "/usr/sbin/networksetup -getinfo 'Thunderbolt Bridge'")
	}
}
