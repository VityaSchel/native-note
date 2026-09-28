import Darwin
import Foundation
import Synchronization
import Testing

@testable import PowerLossKit

private final class Calls: Sendable {
	private let count = Mutex(0)

	var value: Int { count.withLock { $0 } }

	func record() {
		count.withLock { $0 += 1 }
	}
}

private struct Failure: Error, CustomStringConvertible {
	let description = "the PowerLossLibrary volume is not mounted"
}

@Suite(.timeLimit(.minutes(1)))
struct AgentServiceTests {
	private let directory: URL
	private let shutDowns = Calls()

	init() throws {
		directory = try temporaryDirectory()
	}

	private func typist(_ body: String) throws -> URL {
		try script("typist", body)
	}

	private func script(_ name: String, _ body: String) throws -> URL {
		let url = directory.appending(path: name)
		try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
		return url
	}

	private func service(typist: URL, library: @escaping @Sendable () throws -> URL) -> AgentService {
		AgentService(typist: typist, libraryDirectory: library, shutDown: { [shutDowns] in shutDowns.record() })
	}

	private func exchange(_ request: String, with service: AgentService) throws -> [String] {
		try exchange(Data(request.utf8), with: service)
	}

	private func exchange(_ request: Data, with service: AgentService) throws -> [String] {
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, guest) = (ends[0], ends[1])
		defer { close(host) }
		Thread {
			service.serve(input: guest, output: guest)
			close(guest)
		}.start()
		Thread {
			let bytes = Array(request)
			var sent = 0
			while sent < bytes.count {
				let count = bytes.withUnsafeBytes { write(host, $0.baseAddress! + sent, bytes.count - sent) }
				guard count > 0 else { break }
				sent += count
			}
			shutdown(host, SHUT_WR)
		}.start()
		var received: [UInt8] = []
		var buffer = [UInt8](repeating: 0, count: 1024)
		while true {
			let count = buffer.withUnsafeMutableBytes { read(host, $0.baseAddress, $0.count) }
			guard count > 0 else { break }
			received += buffer[..<count]
		}
		return String(decoding: received, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
	}

	private func kit(typist: String, withFramework: Bool = true) throws -> URL {
		let kit = directory.appending(path: "kit-\(typist)")
		try FileManager.default.createDirectory(at: kit, withIntermediateDirectories: true)
		if withFramework {
			let versions = kit.appending(path: "SQLCipher.framework/Versions/A")
			try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
			try Data("library".utf8).write(to: versions.appending(path: "SQLCipher"))
		}
		try Data(typist.utf8).write(to: kit.appending(path: "NativeNoteTypist"))
		try Data("probe".utf8).write(to: kit.appending(path: "power-loss-flush-probe"))
		return kit
	}

	@Test func aKitSentAfterTheInstallRequestIsUnpackedWhereTheTypistRuns() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")
		let service = AgentService(typist: local.appending(path: "NativeNoteTypist"), kit: local, libraryDirectory: { throw Failure() }, shutDown: {})
		let archive = try LocalKit.archive(from: try kit(typist: "sent"))

		let replies = try exchange(Data("install \(archive.count)\n".utf8) + archive, with: service)

		#expect(replies == ["ok", ""])
		#expect(try String(contentsOf: local.appending(path: "NativeNoteTypist"), encoding: .utf8) == "sent")
	}

	@Test func anIncompleteKitIsRefusedWithTheReason() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")
		let service = AgentService(typist: local.appending(path: "NativeNoteTypist"), kit: local, libraryDirectory: { throw Failure() }, shutDown: {})
		let archive = try LocalKit.archive(["NativeNoteTypist"], from: try kit(typist: "alone", withFramework: false))

		let replies = try exchange(Data("install \(archive.count)\n".utf8) + archive, with: service)

		#expect(replies == ["error the kit arrived without SQLCipher.framework", ""])
		#expect(!FileManager.default.fileExists(atPath: local.path))
	}

	@Test func helloAnswersReady() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = service(typist: try typist("exit 9")) { throw Failure() }

		#expect(try exchange("hello\n", with: service) == ["ready", ""])
	}

	@Test func shutdownAnswersBeforeShuttingDown() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, guest) = (ends[0], ends[1])
		defer { close(host) }
		defer { close(guest) }
		let answeredFirst = Calls()
		let service = AgentService(typist: try typist("exit 9"), libraryDirectory: { throw Failure() }) {
			var waiting = [UInt8](repeating: 0, count: 8)
			let count = waiting.withUnsafeMutableBytes { recv(host, $0.baseAddress, $0.count, MSG_PEEK | MSG_DONTWAIT) }
			if count == 3, Array(waiting.prefix(3)) == Array("ok\n".utf8) { answeredFirst.record() }
		}
		_ = Array("shutdown\n".utf8).withUnsafeBytes { write(host, $0.baseAddress, $0.count) }

		service.serve(input: guest, output: guest)

		#expect(answeredFirst.value == 1)
	}

	@Test func typingRelaysEveryTypistLineAndItsExitStatus() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let library = directory.appending(path: "volume/library")
		let typist = try typist(#"printf '[%s]' "$@"; echo; echo "start 0"; echo "warning" >&2; printf 'partial'; exit 3"#)
		let service = service(typist: typist) { library }

		let lines = try exchange("type power loss\n", with: service)

		#expect(lines == ["[acknowledge][\(library.path)][power loss]", "start 0", "warning", "partial", "exit 3", ""])
	}

	@Test func aControlTypingRequestRunsTheTypistInItsControlMode() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let library = directory.appending(path: "volume/library")
		let service = service(typist: try typist(#"printf '[%s]' "$@"; echo"#)) { library }

		let lines = try exchange("type-early-ack power loss\n", with: service)

		#expect(lines == ["[acknowledge-before-saving][\(library.path)][power loss]", "exit 0", ""])
	}

	@Test func keepaliveLinesBeforeTheRequestAreSkipped() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = service(typist: try typist("exit 9")) { throw Failure() }

		#expect(try exchange("\n\nhello\n\n", with: service) == ["ready", ""])
	}

	@Test func aMissingVolumeIsReportedInsteadOfTyping() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = service(typist: try typist("echo typed")) { throw Failure() }

		#expect(try exchange("verify power loss\n", with: service) == ["error the PowerLossLibrary volume is not mounted", ""])
	}

	@Test func diagnoseRunsEveryStepThenAnswersOk() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let steps = [
			DiagnosisStep(DiagnosticCommand("/bin/sh", "-c", "echo disk0; echo disk1 >&2; exit 3"), then: { output in
				output.split(separator: "\n").map { DiagnosticCommand("/bin/echo", "info", String($0)) }
			}),
			DiagnosisStep(DiagnosticCommand(directory.appending(path: "missing").path)),
		]
		let service = AgentService(typist: try typist("exit 9"), diagnosis: steps, libraryDirectory: { throw Failure() }, shutDown: {})

		let lines = try exchange("diagnose\n", with: service)

		#expect(Array(lines.prefix(7)) == [
			"== /bin/sh -c 'echo disk0; echo disk1 >&2; exit 3' (exit 3)",
			"| disk0",
			"| disk1",
			"== /bin/echo info disk0 (exit 0)",
			"| info disk0",
			"== /bin/echo info disk1 (exit 0)",
			"| info disk1",
		])
		#expect(lines[7].hasPrefix("== \(directory.path)/missing (could not run: "))
		#expect(Array(lines.suffix(2)) == ["ok", ""])
		#expect(lines.count == 10)
	}

	@Test func aLibraryProbeRunsOnTheLibraryVolumeAndIsPacedByTheHarness() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let volume = directory.appending(path: "volume")
		let probe = try script("probe", #"echo "on $1"; read first; echo "then $first"; read second; echo "then $second"; exit 4"#)
		let service = AgentService(typist: try typist("exit 9"), probe: probe, libraryDirectory: { volume.appending(path: "library") }, shutDown: {})

		let lines = try exchange("probe library\ngo\nagain\n", with: service)

		#expect(lines == ["on \(volume.path)", "then go", "then again", "exit 4", ""])
	}

	@Test func aSystemProbeRunsInTheSystemFolderWithoutTheLibrary() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = try script("probe", #"echo "on $1""#)
		let service = AgentService(typist: try typist("exit 9"), probe: probe, systemFolder: directory, libraryDirectory: { throw Failure() }, shutDown: {})

		#expect(try exchange("probe system\n", with: service) == ["on \(directory.path)", "exit 0", ""])
	}

	@Test func aLibraryProbeWithoutTheVolumeIsRefused() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = try script("probe", "echo probed")
		let service = AgentService(typist: try typist("exit 9"), probe: probe, libraryDirectory: { throw Failure() }, shutDown: {})

		#expect(try exchange("probe library\n", with: service) == ["error the PowerLossLibrary volume is not mounted", ""])
	}

	@Test func anUnknownRequestIsRefused() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = service(typist: try typist("echo typed")) { directory }

		#expect(try exchange("format disk0\n", with: service) == ["error unknown request", ""])
		#expect(shutDowns.value == 0)
	}

	@Test func anUnfinishedRequestGetsNoAnswer() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let service = service(typist: try typist("echo typed")) { directory }

		#expect(try exchange("shutdown", with: service) == [""])
		#expect(shutDowns.value == 0)
	}
}
