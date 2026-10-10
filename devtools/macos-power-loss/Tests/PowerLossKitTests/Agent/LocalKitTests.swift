import Darwin
import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct LocalKitTests {
	private let directory: URL

	init() throws {
		directory = try temporaryDirectory()
	}

	private func kit(typist: String) throws -> URL {
		let kit = directory.appending(path: "kit-\(typist)")
		let versions = kit.appending(path: "SQLCipher.framework/Versions/A")
		try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
		try Data("library".utf8).write(to: versions.appending(path: "SQLCipher"))
		try FileManager.default.createSymbolicLink(atPath: kit.appending(path: "SQLCipher.framework/Versions/Current").path, withDestinationPath: "A")
		try FileManager.default.createSymbolicLink(atPath: kit.appending(path: "SQLCipher.framework/SQLCipher").path, withDestinationPath: "Versions/Current/SQLCipher")
		let executable = kit.appending(path: "NativeNoteTypist")
		try Data(typist.utf8).write(to: executable)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
		try Data("agent".utf8).write(to: kit.appending(path: "power-loss-agent"))
		try Data("probe".utf8).write(to: kit.appending(path: "power-loss-flush-probe"))
		return kit
	}

	private func install(_ archive: Data, declaring byteCount: Int? = nil, into folder: URL) throws {
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, guest) = (ends[0], ends[1])
		defer { close(guest) }
		Thread {
			archive.withUnsafeBytes { _ = write(host, $0.baseAddress, $0.count) }
			close(host)
		}.start()
		try LocalKit.unpack(from: guest, byteCount: byteCount ?? archive.count, into: folder)
	}

	@Test func theTypistItsFrameworkAndTheProbeArriveWholeOnTheGuestsOwnDisk() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")

		try install(try LocalKit.archive(from: try kit(typist: "first")), into: local)

		#expect(try String(contentsOf: local.appending(path: "NativeNoteTypist"), encoding: .utf8) == "first")
		#expect(FileManager.default.isExecutableFile(atPath: local.appending(path: "NativeNoteTypist").path))
		#expect(try FileManager.default.destinationOfSymbolicLink(atPath: local.appending(path: "SQLCipher.framework/Versions/Current").path) == "A")
		#expect(try String(contentsOf: local.appending(path: "SQLCipher.framework/SQLCipher"), encoding: .utf8) == "library")
		#expect(try String(contentsOf: local.appending(path: "power-loss-flush-probe"), encoding: .utf8) == "probe")
		#expect(!FileManager.default.fileExists(atPath: local.appending(path: "power-loss-agent").path))
		#expect(!FileManager.default.fileExists(atPath: local.path + ".new"))
	}

	@Test func aNewKitReplacesTheLastOneWholly() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")
		try install(try LocalKit.archive(from: try kit(typist: "old")), into: local)
		try Data("stale".utf8).write(to: local.appending(path: "leftover"))

		try install(try LocalKit.archive(from: try kit(typist: "new")), into: local)

		#expect(try String(contentsOf: local.appending(path: "NativeNoteTypist"), encoding: .utf8) == "new")
		#expect(!FileManager.default.fileExists(atPath: local.appending(path: "leftover").path))
	}

	@Test func aKitWithoutItsFrameworkIsRefusedAndTheLastOneStays() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")
		try install(try LocalKit.archive(from: try kit(typist: "good")), into: local)
		let broken = try kit(typist: "broken")

		#expect(throws: LocalKit.Failure.self) {
			try install(try LocalKit.archive(["NativeNoteTypist"], from: broken), into: local)
		}

		#expect(try String(contentsOf: local.appending(path: "NativeNoteTypist"), encoding: .utf8) == "good")
		#expect(!FileManager.default.fileExists(atPath: local.path + ".new"))
	}

	@Test func aKitCutShortIsRefusedAndTheLastOneStays() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let local = directory.appending(path: "Shared/NativeNotePowerLoss")
		try install(try LocalKit.archive(from: try kit(typist: "good")), into: local)
		let archive = try LocalKit.archive(from: try kit(typist: "short"))

		#expect(throws: LocalKit.Failure.self) {
			try install(archive.prefix(archive.count / 2), declaring: archive.count, into: local)
		}

		#expect(try String(contentsOf: local.appending(path: "NativeNoteTypist"), encoding: .utf8) == "good")
	}

	@Test func packingAKitThatLacksAnItemFails() throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let broken = try kit(typist: "broken")
		try FileManager.default.removeItem(at: broken.appending(path: "SQLCipher.framework"))

		#expect(throws: LocalKit.Failure.self) { try LocalKit.archive(from: broken) }
	}

	@Test func theAgentRunsTheTypistAndTheProbeFromTheGuestsOwnDisk() {
		#expect(LocalKit.typist.path == "/Users/Shared/NativeNotePowerLoss/NativeNoteTypist")
		#expect(LocalKit.probe.path == "/Users/Shared/NativeNotePowerLoss/power-loss-flush-probe")
	}
}
