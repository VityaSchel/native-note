import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch)
struct NoteExtTests {
	private let cipher = NoteCipher(contentKey: sharedContentKey)
	private let ext = Data([0x65, 0x78, 0x74, 0x00, 0xff, 0x00])

	private func pull(_ content: Content, v: UInt32, into store: NoteStore) async throws -> Applied {
		let write = try cipher.seal(content, v: v)
		return try await store.commit(.exchange(Exchange(changes: [PulledChange(content: content, v: v, writeId: write.writeId)], nextSeq: UInt64(v))))
	}

	private func pushedContent(of store: NoteStore) async throws -> [Content] {
		let server = ScriptedServer()
		server.answerEvery { request in
			guard case let .sync(since, writes) = request else { return .error(.malformed) }
			return .sync(results: writes.map { WriteResult(status: .accepted, v: $0.v) }, changes: [], nextSeq: since, more: false)
		}
		_ = try await server.device(store).sync()
		return server.requests.flatMap { request -> [Write] in
			if case let .sync(_, writes) = request { writes } else { [] }
		}.compactMap(cipher.open)
	}

	@Test func aPulledNoteKeepsItsExtThroughALocalEditAndPushesItBack() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let id = UUID()
		_ = try await pull(.note(id: id, createdAt: 1, updatedAt: 2, body: "from a newer Mac", ext: ext), v: 1, into: store)
		var shown = try #require(try await store.note(id: id))
		#expect(shown.ext == ext)

		shown.body = "edited here"
		shown.updatedAt = 3
		shown.dirty = true
		shown.ext = Data()
		try await store.save(shown)

		#expect(try await store.note(id: id)?.ext == ext)
		#expect(try await pushedContent(of: store) == [.note(id: id, createdAt: 1, updatedAt: 3, body: "edited here", ext: ext)])
		#expect(try await store.note(id: id).map { !$0.dirty && $0.v == 2 && $0.ext == ext } == true)
	}

	@Test func aNewNotePushesAnEmptyExt() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let note = Note(id: UUID(), body: "new here", createdAt: 1, updatedAt: 2, dirty: true)
		try await store.save(note)

		#expect(try await pushedContent(of: store) == [.note(id: note.id, createdAt: 1, updatedAt: 2, body: "new here", ext: Data())])
	}

	@Test func aConflictCopyTakesTheExtOfTheTextItCopies() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let id = UUID()
		_ = try await pull(.note(id: id, createdAt: 1, updatedAt: 2, body: "first", ext: ext), v: 1, into: store)
		var local = try #require(try await store.note(id: id))
		local.body = "unpushed here"
		local.dirty = true
		try await store.save(local)
		let theirs = Data([0x02])

		let applied = try await pull(.note(id: id, createdAt: 1, updatedAt: 5, body: "edited elsewhere", ext: theirs), v: 2, into: store)

		let copyId = try #require(applied.copies[id])
		let copy = try #require(try await store.note(id: copyId))
		#expect((copy.body, copy.ext, copy.v, copy.dirty) == ("unpushed here", ext, 0, true))
		#expect(try await store.note(id: id).map { ($0.body, $0.ext) == ("edited elsewhere", theirs) } == true)
	}

	@Test func anEditThatLandsAsACopyAfterAPullTakesTheExtItWasTypedOn() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let id = UUID()
		_ = try await pull(.note(id: id, createdAt: 1, updatedAt: 2, body: "first", ext: ext), v: 1, into: store)
		var typing = try #require(try await store.note(id: id))
		_ = try await pull(.note(id: id, createdAt: 1, updatedAt: 5, body: "edited elsewhere", ext: Data([0x02])), v: 2, into: store)
		typing.body = "typed meanwhile"
		typing.dirty = true

		guard case let .copied(copy) = try await store.save(typing) else {
			Issue.record("the edit landed on the pulled text")
			return
		}
		#expect(try await store.note(id: copy).map { ($0.body, $0.ext) == ("typed meanwhile", ext) } == true)
		#expect(try await store.note(id: id)?.ext == Data([0x02]))
	}

	@Test func aDeletedNoteKeepsNoExt() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let id = UUID()
		_ = try await pull(.note(id: id, createdAt: 1, updatedAt: 2, body: "doomed", ext: ext), v: 1, into: store)

		try await store.markDeleted(id: id, at: 9)

		#expect(try await store.note(id: id).map { $0.deleted && $0.ext.isEmpty } == true)
		#expect(try await pushedContent(of: store) == [.tombstone(id: id, deletedAt: 9)])
	}
}
