import Foundation
import Testing

@testable import NativeNoteKit

extension NoteStore {
	fileprivate func wait(at gate: Gate) {
		gate.hold()
	}

	fileprivate func execute(_ statement: String) throws {
		try connection.execute(statement)
	}
}

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct SyncRaceTests {
	private let alarm = Alarm()
	private let id = UUID()

	private func pull(_ body: String, v: UInt32, updatedAt: Int64 = 1) -> Commit {
		let content = Content.note(id: id, createdAt: 1, updatedAt: updatedAt, body: body)
		return .exchange(Exchange(changes: [PulledChange(content: content, v: v, writeId: NoteCipher.randomWriteId())], nextSeq: UInt64(v)))
	}

	private func acknowledgment(of id: UUID, v: UInt32, in store: NoteStore) async throws -> Commit {
		let pushed = try #require(try await store.note(id: id))
		let content = Content.note(id: id, createdAt: pushed.createdAt, updatedAt: pushed.updatedAt, body: pushed.body)
		let sent = SealedWrite(note: pushed, write: try NoteCipher(contentKey: sharedContentKey).seal(content, v: v))
		return .exchange(Exchange(sent: [sent], results: [WriteResult(status: .accepted, v: v)], nextSeq: UInt64(v)))
	}

	private func library() async throws -> (AppModel, NoteStore) {
		let (model, _) = try await unlockedModel(alarm: alarm)
		let store = try #require(model.store)
		_ = try await model.commit(pull("Draft", v: 1), to: store)
		try #require(model.notes.map(\.body) == ["Draft"])
		model.selection = id
		return (model, store)
	}

	private func committing(_ commit: Commit, in model: AppModel, _ store: NoteStore, meanwhile: () -> Void) async throws -> Applied {
		let gate = Gate()
		let blocking = Task { await store.wait(at: gate) }
		try await gate.untilHolding()
		let committing = Task { try await model.commit(commit, to: store) }
		await Task.yield()
		meanwhile()
		do { try await settle { !model.scheduler.isPending(id) } } catch { gate.open(); throw error }
		gate.open()
		await blocking.value
		let applied = try await committing.value
		await model.flushPendingSaves()
		return applied
	}

	private func onDisk(_ store: NoteStore) async throws -> Set<String> {
		Set(try await store.liveNotes().map(\.body))
	}

	@Test func anEditLeftWhileAPullOfItsNoteCommitsKeepsBothTexts() async throws {
		let (model, store) = try await library()

		let applied = try await committing(pull("from the other device", v: 2), in: model, store) {
			model.edit(id, "typed here")
			model.selection = nil
		}

		try #require(applied.pulled == [id] && applied.copies.isEmpty, "the save reached the store after the pull")
		#expect(Set(model.notes.map(\.body)) == ["typed here", "from the other device"])
		await alarm.ring()
		await model.flushPendingSaves()
		#expect(try await onDisk(store) == ["typed here", "from the other device"])
	}

	@Test func anEditFlushedWithItsNoteOpenWhileAPullCommitsMovesToACopyTheEditorFollows() async throws {
		let (model, store) = try await library()

		let applied = try await committing(pull("from the other device", v: 2), in: model, store) {
			model.edit(id, "typed here")
			Task { await model.flushPendingSaves() }
		}

		try #require(applied.pulled == [id] && applied.copies.isEmpty, "the save reached the store after the pull")
		#expect(model.selectedNote?.body == "typed here")
		#expect(model.selection != id)
		#expect(Set(model.notes.map(\.body)) == ["typed here", "from the other device"])
		#expect(try await onDisk(store) == ["typed here", "from the other device"])
	}

	@Test func anEditFlushedWhileItsEarlierPushIsAcknowledgedStaysInTheEditor() async throws {
		let (model, store) = try await library()
		model.edit(id, "pushed")
		await model.flushPendingSaves()

		let applied = try await committing(try await acknowledgment(of: id, v: 2, in: store), in: model, store) {
			model.edit(id, "typed since")
			Task { await model.flushPendingSaves() }
		}

		try #require(applied.changed[id]?.body == "pushed", "the save reached the store after the acknowledgement")
		#expect(model.selectedNote?.body == "typed since")
		#expect(try await onDisk(store) == ["typed since"])
		#expect(try await store.note(id: id)?.dirty == true)
	}

	@Test func aKeystrokeFromBeforeAPullNeverOverwritesThePulledText() async throws {
		let (model, store) = try await library()
		let shown = try #require(model.selectedNote)
		_ = try await model.commit(pull("from the other device", v: 2), to: store)

		model.edit(id, "Draft and a late key", shownAt: shown.v)
		await model.flushPendingSaves()

		#expect(model.selectedNote?.body == "Draft and a late key")
		#expect(Set(model.notes.map(\.body)) == ["Draft and a late key", "from the other device"])
		await model.flushPendingSaves()
		#expect(try await onDisk(store) == ["Draft and a late key", "from the other device"])
	}

	@Test func aKeystrokeFromBeforeAnAcknowledgmentStaysInItsNote() async throws {
		let (model, store) = try await library()
		model.edit(id, "pushed")
		await model.flushPendingSaves()
		let shown = try #require(model.selectedNote)
		_ = try await model.commit(try await acknowledgment(of: id, v: 2, in: store), to: store)
		try #require(model.selectedNote?.v == 2)

		model.edit(id, "pushed, and a late key", shownAt: shown.v)
		await model.flushPendingSaves()

		#expect(model.notes.map(\.body) == ["pushed, and a late key"])
		#expect(try await onDisk(store) == ["pushed, and a late key"])
	}

	@Test func aSaveThatFailsAfterAPullReplacedItsNoteIsRetriedWithTheTypedText() async throws {
		let (model, store) = try await library()
		try await store.execute("CREATE TRIGGER full BEFORE INSERT ON note WHEN new.body LIKE 'typed%' BEGIN SELECT RAISE(ABORT, 'disk full'); END")

		let applied = try await committing(pull("from the other device", v: 2, updatedAt: Date.distantFuture.epochMilliseconds), in: model, store) {
			model.edit(id, "typed here")
			model.selection = nil
		}
		try #require(applied.pulled == [id] && applied.copies.isEmpty, "the save reached the store after the pull")
		try #require(model.unsavedReason == "disk full")
		try await store.execute("DROP TRIGGER full")
		await model.flushPendingSaves()

		#expect(Set(model.notes.map(\.body)) == ["typed here", "from the other device"])
		#expect(try await onDisk(store) == ["typed here", "from the other device"])
	}

	@Test func textTypedOnAPulledNoteStaysWhenAnEarlierSaveBecomesItsCopy() async throws {
		let (model, store) = try await library()
		let earlier = try #require(model.selectedNote)
		_ = try await model.commit(pull("from the other device", v: 2), to: store)
		model.edit(id, "from the other device, and more", shownAt: 2)

		await model.saveBecameCopy(earlier, copy: UUID(), in: store)

		#expect(Set(model.notes.map(\.body)) == ["Draft", "from the other device, and more"])
	}

	private func readingTheNote(itsEditMovedFrom edited: Note, in model: AppModel, _ store: NoteStore, meanwhile: () async throws -> Void) async throws {
		let gate = Gate()
		let blocking = Task { await store.wait(at: gate) }
		try await gate.untilHolding()
		let becoming = Task { await model.saveBecameCopy(edited, copy: UUID(), in: store) }
		await Task.yield()
		do {
			try #require(model.selection != id, "the edit moved and its note is being read")
			try await meanwhile()
		} catch { gate.open(); throw error }
		gate.open()
		await blocking.value
		await becoming.value
	}

	@Test func aNoteReadWhileTheLibraryLocksIsNotShown() async throws {
		let (model, store) = try await library()
		var locking: Task<Void, Never>?

		try await readingTheNote(itsEditMovedFrom: try #require(model.selectedNote), in: model, store) {
			locking = Task { await model.lock() }
			await Task.yield()
			try #require(model.notes.isEmpty)
		}
		await locking?.value

		#expect(model.notes.isEmpty)
	}

	@Test func aNoteTypedInWhileItIsReadKeepsThatText() async throws {
		let (model, store) = try await library()

		try await readingTheNote(itsEditMovedFrom: try #require(model.selectedNote), in: model, store) {
			model.selection = id
			model.edit(id, "back and typing", shownAt: 1)
		}

		#expect(model.selectedNote?.body == "back and typing")
	}
}
