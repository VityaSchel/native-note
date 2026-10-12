import Foundation
import Testing

@testable import NativeNoteKit

/// A save carries the `v` its edit began at; it never overwrites text a pull wrote after that.
@MainActor
struct SaveArbitrationTests {
	private func pulled(_ store: NoteStore, _ note: Note, body: String, v: UInt32) async throws {
		let cipher = NoteCipher(contentKey: sharedContentKey)
		let content = Content.note(id: note.id, createdAt: note.createdAt, updatedAt: 9, body: body)
		let write = try cipher.seal(content, v: v)
		_ = try await store.commit(.exchange(Exchange(changes: [PulledChange(content: content, v: v, writeId: write.writeId)], nextSeq: 1)))
	}

	@Test func anEditBegunBeforeAPullLandsAsANewNoteAndLeavesThePulledText() async throws {
		let store = try await openStore(at: temporaryDatabase())
		var note = Note(id: UUID(), body: "draft", createdAt: 1, updatedAt: 2, v: 1)
		try await store.save(note)
		try await pulled(store, note, body: "from elsewhere", v: 2)
		note.body = "typed here meanwhile"

		guard case let .copied(copy) = try await store.save(note) else {
			Issue.record("the edit landed on the pulled text")
			return
		}
		let original = try #require(try await store.note(id: note.id))
		#expect(original.body == "from elsewhere" && original.v == 2 && !original.dirty)
		let saved = try #require(try await store.note(id: copy))
		#expect(saved.body == "typed here meanwhile" && saved.dirty && saved.v == 0)
	}

	@Test func anEditBegunBeforeAPullThatDeletedTheNoteKeepsItsText() async throws {
		let store = try await openStore(at: temporaryDatabase())
		var note = Note(id: UUID(), body: "draft", createdAt: 1, updatedAt: 2, v: 1)
		try await store.save(note)
		let tombstone = Content.tombstone(id: note.id, deletedAt: 9)
		_ = try await store.commit(.exchange(Exchange(changes: [PulledChange(content: tombstone, v: 2, writeId: Data(count: 16))], nextSeq: 1)))
		note.body = "still needed"

		guard case let .copied(copy) = try await store.save(note) else {
			Issue.record("the edit was dropped on the tombstone")
			return
		}
		#expect(try await store.note(id: copy)?.body == "still needed")
		#expect(try await store.note(id: note.id)?.deleted == true)
	}

	@Test func anEditOfOurOwnAcknowledgedTextOrAtTheCurrentVersionSavesInPlace() async throws {
		let store = try await openStore(at: temporaryDatabase())
		var note = Note(id: UUID(), body: "draft", createdAt: 1, updatedAt: 2, dirty: true)
		try await store.save(note)
		let write = try NoteCipher(contentKey: sharedContentKey).seal(.note(id: note.id, createdAt: 1, updatedAt: 2, body: "draft"), v: 1)
		_ = try await store.commit(.exchange(Exchange(
			sent: [SealedWrite(note: note, write: write)],
			results: [WriteResult(status: .accepted, v: 1, seq: 1)],
			nextSeq: 1
		)))
		note.body = "typed after the push was sealed"

		#expect(try await store.save(note) == .saved)
		let acknowledged = try #require(try await store.note(id: note.id))
		#expect(acknowledged.body == note.body && acknowledged.v == 1 && acknowledged.dirty)

		try await pulled(store, note, body: "pulled at two", v: 2)
		note.v = 2
		note.body = "edited after seeing the pull"
		#expect(try await store.save(note) == .saved)
		#expect(Set(try await store.liveNotes().map(\.body)) == ["edited after seeing the pull", "typed after the push was sealed"])
	}

	@Test func aSaveNeverWritesOverAnOwnTombstone() async throws {
		let store = try await openStore(at: temporaryDatabase())
		var note = Note(id: UUID(), body: "draft", createdAt: 1, updatedAt: 2, dirty: true)
		try await store.save(note)
		try await store.markDeleted(id: note.id, at: 3)
		note.body = "a late save"

		#expect(try await store.save(note) == .saved)
		let tombstone = try #require(try await store.note(id: note.id))
		#expect(tombstone.deleted && tombstone.body.isEmpty)
	}
}
