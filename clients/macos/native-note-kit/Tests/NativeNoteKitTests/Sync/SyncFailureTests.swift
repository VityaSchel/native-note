import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct SyncFailureTests {
	@Test func aWriteWhoseResponseWasLostIsRecognizedByItsWriteIdAndMakesNoCopy() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let id = try await a.write("first")
		a.transport.failNext(.dropResponse)
		await #expect(throws: URLError.self) { try await a.sync() }

		let applied = try await a.sync()

		#expect(applied.copies.isEmpty)
		#expect(try await a.note(id)?.v == 1)
		#expect(try await a.dirty.isEmpty)
	}

	@Test func anEditAfterALostResponseStaysDirtyAndPushesAtTheNextVersion() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let id = try await a.write("first")
		a.transport.failNext(.dropResponse)
		await #expect(throws: URLError.self) { try await a.sync() }
		try await a.write("second", to: id)

		let applied = try await a.sync()
		try await a.sync()
		try await b.sync()

		#expect(applied.copies.isEmpty)
		#expect(try await a.note(id)?.v == 2)
		#expect(try await b.live() == [id: "second"])
	}

	@Test func afterARelaunchALostResponseTakesTheCopyPathWhereMatchingTextMakesNoCopy() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let id = try await a.write("first")
		a.transport.failNext(.dropResponse)
		await #expect(throws: URLError.self) { try await a.sync() }
		a.relaunch()

		let applied = try await a.sync()

		#expect(applied.copies.isEmpty)
		#expect(try await a.live() == [id: "first"])
		#expect(try await a.dirty.isEmpty)
	}

	@Test func aDroppedRequestOrAServerKilledMidRequestLosesNothing() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		var expected: [UUID: String] = [:]
		for (round, fault) in [TestTransport.Fault.dropRequest, .killServer, .killServer, .killServer].enumerated() {
			let id = try await a.write("note \(round)")
			expected[id] = "note \(round)"
			a.transport.failNext(fault)
			await #expect(throws: URLError.self) { try await a.sync() }
			let applied = try await a.sync()
			#expect(applied.copies.isEmpty, "round \(round)")
		}
		try await b.sync()

		#expect(try await b.live() == expected)
		#expect(try await a.dirty.isEmpty)
	}

	@Test func aServerRestoredFromAnOldBackupIsReportedAndNotRetriedInALoop() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let id = try await a.write("v1")
		try await a.sync()
		server.kill()
		let backup = temporaryDirectory()
		try FileManager.default.copyItem(at: server.data, to: backup)
		defer { try? FileManager.default.removeItem(at: backup) }
		try server.start()
		try await a.write("v2", to: id)
		try await a.sync()
		try await a.write("v3", to: id)
		try await a.sync()

		server.kill()
		try FileManager.default.removeItem(at: server.data)
		try FileManager.default.copyItem(at: backup, to: server.data)
		try server.start()
		try await a.write("v4", to: id)
		let posted = a.transport.posted
		let applied = try await a.sync()

		#expect(applied.problems.contains(.serverBehind))
		#expect(a.transport.posted - posted == 1)
		#expect(try await a.store.since() == 3)
		#expect(try await a.live() == [id: "v4"])
	}

	@Test func aChangeSealedUnderAnotherContentKeyIsReportedAndNotApplied() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let stranger = try await SyncDevice(server, contentKey: SymmetricKey(size: .bits256))
		try await stranger.write("planted")
		try await stranger.sync()
		let id = try await a.write("mine")

		let applied = try await a.sync()

		#expect(applied.problems == [.unverifiableChange])
		#expect(try await a.live() == [id: "mine"])
		#expect(try await a.store.since() == 2)
	}

	@Test func aDirtyNoteAtTheLastVersionMovesItsTextToACopyWithoutAPush() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let last = Note(id: UUID(), body: "unpushable", createdAt: 1, updatedAt: 2, dirty: true, v: .max)
		let deleted = Note(id: UUID(), body: "", createdAt: 1, updatedAt: 2, deleted: true, dirty: true, v: .max)
		try await a.store.save(last)
		try await a.store.save(deleted)

		let applied = try await a.sync()

		let copy = try #require(applied.copies[last.id])
		#expect(applied.copies.count == 1)
		let original = try #require(try await a.note(last.id))
		#expect(original.body == "unpushable" && !original.dirty && original.v == .max)
		#expect(try await a.note(deleted.id)?.dirty == false)
		let pushed = try #require(try await a.note(copy))
		#expect(pushed.body == "unpushable" && pushed.v == 1)
		#expect(try await a.dirty.isEmpty)
	}

	@Test func aNoteOverTheLimitStaysDirtyAndIsReportedWhileTheRestPush() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let huge = try await a.write(String(repeating: "x", count: SyncEngine.noteMax))
		let small = try await a.write("small")

		let applied = try await a.sync()

		#expect(applied.problems == [.tooLarge(huge)])
		#expect(try await a.dirty.map(\.id) == [huge])
		#expect(try await a.note(small)?.v == 1)
	}

	@Test func writesPastOneRequestPushInSeveralAndPullInSeveralPages() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		var expected: [UUID: String] = [:]
		for index in 0 ..< 6 {
			let body = String(repeating: Character(UnicodeScalar(UInt8(97 + index))), count: 700_000)
			expected[try await a.write(body)] = body
		}

		try await a.sync()
		try await b.sync()

		#expect(a.transport.posted >= 3)
		#expect(b.transport.posted >= 3)
		#expect(try await b.live() == expected)
		#expect(try await b.store.since() == 6)
	}
}
