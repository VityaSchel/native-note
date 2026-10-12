import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct SyncVerificationTests {
	private let cipher = NoteCipher(contentKey: sharedContentKey)

	private func library() async throws -> NoteStore {
		try await openStore(at: temporaryDatabase())
	}

	private func note(_ body: String, v: UInt32 = 0, dirty: Bool = true) -> Note {
		Note(id: UUID(), body: body, createdAt: 1, updatedAt: 2, dirty: dirty, v: v)
	}

	private func change(_ note: Note, v: UInt32) throws -> Write {
		try cipher.seal(.note(id: note.id, createdAt: note.createdAt, updatedAt: note.updatedAt, body: note.body), v: v)
	}

	@Test(arguments: [
		"too few results", "an accepted result at another version", "an accepted result without a seq", "more with no changes",
	])
	func aResponseTheProtocolForbidsIsRefusedWhole(_ violation: String) async throws {
		let store = try await library()
		let pushed = note("pushed")
		try await store.save(pushed)
		let server = ScriptedServer()
		let other = try change(note("from elsewhere"), v: 1)
		server.answer { _ in
			switch violation {
			case "too few results": .sync(results: [], changes: [other], nextSeq: 1, more: false)
			case "an accepted result at another version": .sync(results: [WriteResult(status: .accepted, v: 2, seq: 1)], changes: [], nextSeq: 1, more: false)
			case "an accepted result without a seq": .sync(results: [WriteResult(status: .accepted, v: 1, seq: 0)], changes: [], nextSeq: 1, more: false)
			default: .sync(results: [WriteResult(status: .accepted, v: 1, seq: 1)], changes: [], nextSeq: 1, more: true)
			}
		}

		await #expect(throws: SyncError.protocolViolation) { try await server.device(store).sync() }

		#expect(try await store.liveNotes().map(\.body) == ["pushed"])
		#expect(try await store.note(id: pushed.id).map { $0.dirty && $0.v == 0 } == true)
		#expect(try await store.since() == 0)
	}

	@Test func aChangeWhoseTextNamesAnotherNoteIsReportedAndNotApplied() async throws {
		let store = try await library()
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

	@Test func aPulledVersionBelowTheLocalOneOrAPushConflictBelowItReportsTheServerBehind() async throws {
		let store = try await library()
		let held = note("at five", v: 5, dirty: false)
		let edited = note("edited at three", v: 3)
		try await store.save(held)
		try await store.save(edited)
		let server = ScriptedServer()
		let stale = try change(Note(id: held.id, body: "stale", createdAt: 1, updatedAt: 1), v: 4)
		server.answer { _ in .sync(results: [WriteResult(status: .conflict, v: 2, seq: 0)], changes: [stale], nextSeq: 1, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems == [.serverBehind, .serverBehind])
		#expect(try await store.note(id: held.id)?.body == "at five")
		#expect(try await store.note(id: edited.id).map { $0.dirty && $0.v == 3 } == true)
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
