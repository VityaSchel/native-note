import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch)
struct SyncVerificationTests {
	private let cipher = NoteCipher(contentKey: sharedContentKey)

	private func note(_ body: String, v: UInt32 = 0, dirty: Bool = true) -> Note {
		Note(id: UUID(), body: body, createdAt: 1, updatedAt: 2, dirty: dirty, v: v)
	}

	private func change(_ note: Note, v: UInt32) throws -> Write {
		try cipher.seal(.note(id: note.id, createdAt: note.createdAt, updatedAt: note.updatedAt, body: note.body), v: v)
	}

	@Test(arguments: [
		"too few results", "an accepted result at another version", "more with no changes",
	])
	func aResponseTheProtocolForbidsIsRefusedWhole(_ violation: String) async throws {
		let store = try await openStore(at: temporaryDatabase())
		let pushed = note("pushed")
		try await store.save(pushed)
		let server = ScriptedServer()
		let other = try change(note("from elsewhere"), v: 1)
		server.answer { _ in
			switch violation {
			case "too few results": .sync(results: [], changes: [other], nextSeq: 1, more: false)
			case "an accepted result at another version": .sync(results: [WriteResult(status: .accepted, v: 2)], changes: [], nextSeq: 1, more: false)
			default: .sync(results: [WriteResult(status: .accepted, v: 1)], changes: [], nextSeq: 1, more: true)
			}
		}

		await #expect(throws: SyncError.protocolViolation) { try await server.device(store).sync() }

		#expect(try await store.liveNotes().map(\.body) == ["pushed"])
		#expect(try await store.note(id: pushed.id).map { $0.dirty && $0.v == 0 } == true)
		#expect(try await store.since() == 0)
	}

	@Test func aChangeWhoseTextNamesAnotherNoteIsReportedAndNotApplied() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let mine = note("mine", v: 3, dirty: false)
		try await store.save(mine)
		let server = ScriptedServer()
		let planted = try misfiled(.note(id: UUID(), createdAt: 1, updatedAt: 2, body: "planted"), under: cipher.blindedId(for: mine.id), v: 4)
		server.answer { _ in .sync(results: [], changes: [planted], nextSeq: 9, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.unverifiableChange])
		#expect(try await store.liveNotes().map(\.body) == ["mine"])
		#expect(try await store.since() == 9)
	}

	@Test(arguments: [(UInt8(0x02), UInt8(0x01)), (0x01, 0x03), (0x01, 0x7f), (0xff, 0x02)])
	func aChangeFromANewerVersionIsReportedAsSuchAndSkipped(version: UInt8, kind: UInt8) async throws {
		let store = try await openStore(at: temporaryDatabase())
		let mine = note("mine", v: 3, dirty: false)
		try await store.save(mine)
		let server = ScriptedServer()
		let newer = try sealed(newerContent(of: mine.id, version: version, kind: kind), under: cipher.blindedId(for: mine.id), v: 4)
		let elsewhere = UUID()
		let unpadded = try sealed(Data([version, kind]) + elsewhere.bytes, under: cipher.blindedId(for: elsewhere), v: 1)
		#expect(cipher.open(newer) == nil && cipher.open(unpadded) == nil)
		server.answer { _ in .sync(results: [], changes: [newer, unpadded], nextSeq: 9, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.newerChange, .newerChange])
		#expect(applied.changed.isEmpty)
		#expect(try await store.liveNotes().map { ($0.body, $0.v) }.elementsEqual([("mine", 3)], by: ==))
		#expect(try await store.since() == 9)
	}

	@Test func aChangeFromANewerVersionWithoutAPrefixFromThisLibraryIsUnverifiable() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let mine = note("mine", v: 3, dirty: false)
		try await store.save(mine)
		let server = ScriptedServer()
		let blindedId = cipher.blindedId(for: mine.id)
		let changes = [
			try sealed(newerContent(of: UUID()), under: blindedId, v: 4),
			try sealed(newerContent(of: mine.id), under: blindedId, v: 4, contentKey: .init(size: .bits256)),
			try sealed(Data([0x02, 0x01]) + mine.id.bytes.prefix(15), under: blindedId, v: 4),
		]
		server.answer { _ in .sync(results: [], changes: changes, nextSeq: 9, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == Array(repeating: .unverifiableChange, count: 3))
		#expect(try await store.liveNotes().map(\.body) == ["mine"])
	}

	@Test func aChangeOfAKnownVersionThatDoesNotDecodeStaysUnverifiable() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let mine = note("mine", v: 3, dirty: false)
		try await store.save(mine)
		let server = ScriptedServer()
		let blindedId = cipher.blindedId(for: mine.id)
		var unpadded = Content.note(id: mine.id, createdAt: 1, updatedAt: 2, body: "short").encoded()
		unpadded.removeLast(1)
		let changes = [
			try sealed(newerContent(of: mine.id, version: 0x01, kind: 0x01), under: blindedId, v: 4),
			try sealed(newerContent(of: mine.id, version: 0x01, kind: 0x02, fields: Data(repeating: 1, count: 9)), under: blindedId, v: 4),
			try sealed(unpadded, under: blindedId, v: 4),
		]
		server.answer { _ in .sync(results: [], changes: changes, nextSeq: 9, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == Array(repeating: .unverifiableChange, count: 3))
		#expect(try await store.liveNotes().map(\.body) == ["mine"])
	}

	@Test func aPushConflictAtAVersionThatNeverArrivesIsReportedOnceThePullReachesTheHeadAndStaysDirty() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let stuck = note("edited at two", v: 2)
		try await store.save(stuck)
		let server = ScriptedServer()
		let elsewhere = try change(Note(id: UUID(), body: "elsewhere", createdAt: 1, updatedAt: 1), v: 1)
		server.answer { _ in .sync(results: [WriteResult(status: .conflict, v: 4)], changes: [elsewhere], nextSeq: 3, more: true) }
		server.answer { _ in .sync(results: [], changes: [elsewhere], nextSeq: 4, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.stuckConflict(stuck.id)])
		#expect(try await store.note(id: stuck.id).map { $0.dirty && $0.v == 2 && $0.body == "edited at two" } == true)
		#expect(server.requests.count == 2)
	}

	@Test func aPushConflictWhoseVersionArrivesInThePullIsNotReported() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let edited = note("edited here", v: 2)
		try await store.save(edited)
		let server = ScriptedServer()
		let theirs = try change(Note(id: edited.id, body: "edited elsewhere", createdAt: 1, updatedAt: 3), v: 3)
		server.answer { _ in .sync(results: [WriteResult(status: .conflict, v: 3)], changes: [theirs], nextSeq: 3, more: false) }
		server.answerEvery { request in
			guard case let .sync(since, writes) = request else { return .error(.malformed) }
			return .sync(results: writes.map { WriteResult(status: .accepted, v: $0.v) }, changes: [], nextSeq: since, more: false)
		}

		let applied = try await server.device(store).sync()

		#expect(applied.problems.isEmpty)
		#expect(applied.copies[edited.id] != nil)
		#expect(try await store.note(id: edited.id).map { !$0.dirty && $0.v == 3 } == true)
	}

	@Test func aPushConflictBelowTheLocalVersionIsTheServerBehindNotAStuckNote() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let edited = note("edited at five", v: 5)
		try await store.save(edited)
		let server = ScriptedServer()
		server.answer { _ in .sync(results: [WriteResult(status: .conflict, v: 3)], changes: [], nextSeq: 3, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.serverBehind])
	}

	@Test func aPulledVersionBelowTheLocalOneOrAPushConflictBelowItReportsTheServerBehind() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let held = note("at five", v: 5, dirty: false)
		let edited = note("edited at three", v: 3)
		try await store.save(held)
		try await store.save(edited)
		let server = ScriptedServer()
		let stale = try change(Note(id: held.id, body: "stale", createdAt: 1, updatedAt: 1), v: 4)
		server.answer { _ in .sync(results: [WriteResult(status: .conflict, v: 2)], changes: [stale], nextSeq: 1, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.serverBehind, .serverBehind])
		#expect(try await store.note(id: held.id)?.body == "at five")
		#expect(try await store.note(id: edited.id).map { $0.dirty && $0.v == 3 } == true)
		#expect(server.requests.count == 1)
	}

	@Test func theLargestNoteThatFitsItsFilledPayloadSyncsAndOneByteMoreStaysHere() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let largest = note(String(repeating: "a", count: 255 * Content.block - 42))
		let over = note(String(repeating: "a", count: 255 * Content.block - 41))
		try await store.save(largest)
		try await store.save(over)
		let server = ScriptedServer()
		server.answer { _ in .sync(results: [WriteResult(status: .accepted, v: 1)], changes: [], nextSeq: 1, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.tooLarge(over.id)])
		guard case let .sync(_, writes) = try #require(server.requests.first) else {
			Issue.record("the push was not a sync")
			return
		}
		#expect(writes.map(\.payload.count) == [255 * Content.block + 28])
		#expect(try await store.note(id: largest.id)?.dirty == false)
		#expect(try await store.note(id: over.id)?.dirty == true)
	}

	@Test func aWriteTheServerAnswersTooLargeStaysDirtyHereAndIsReportedWithoutARetry() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let refused = note("refused by the server")
		try await store.save(refused)
		let server = ScriptedServer()
		server.answer { _ in .sync(results: [WriteResult(status: .tooLarge, v: 0)], changes: [], nextSeq: 7, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.tooLarge(refused.id)])
		#expect(applied.changed.isEmpty && applied.copies.isEmpty)
		#expect(try await store.note(id: refused.id).map { $0.dirty && $0.v == 0 && $0.body == "refused by the server" } == true)
		#expect(try await store.since() == 7)
		#expect(server.requests.count == 1)
	}

	@Test func aRecoveryPutConflictBelowThePinReportsTheServerBehind() async throws {
		let server = ScriptedServer()
		server.answer { _ in .put(status: .conflict, v: 1) }
		let flow = RecoveryFlow(connection: SyncConnection(apiKey: server.apiKey, transport: server))

		await #expect(throws: RecoveryFlow.Failure.serverBehind) {
			try await flow.put(sharedContentKey, under: SymmetricKey(size: .bits256), pin: 3)
		}
		#expect(server.requests == [.put(v: 4, blob: try #require(server.requests.first.flatMap { if case let .put(_, blob) = $0 { blob } else { nil } }))])
	}
}
