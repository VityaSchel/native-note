import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch)
struct UndoDeleteTests {
	private let alarm = Alarm()

	@Test func aDeletedNoteComesBackAsANewNoteWithItsUnsavedTextAndItsTimes() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kept text"])
		let original = try #require(model.selectedNote)
		model.edit(original.id, "kept text, typed just before deleting")
		let typed = try #require(model.selectedNote)

		let kept = try #require(model.keepForUndo(original.id))
		await model.delete(original.id)
		let restored = try #require(model.restore(kept))

		#expect(restored != original.id)
		#expect(model.selection == restored)
		#expect(model.notes.map(\.body) == ["kept text, typed just before deleting"])
		#expect(await model.flushPendingSaves())
		let disk = try await observer(of: directory)
		let saved = try #require(try await disk.note(id: restored))
		#expect(saved.body == typed.body && saved.createdAt == original.createdAt && saved.updatedAt == typed.updatedAt && saved.dirty)
		#expect(try await disk.note(id: original.id)?.deleted == true)
		#expect(model.restore(kept) == nil)
	}

	@Test func nothingComesBackWhileTheOriginalStillLives() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["not deleted after all"])
		let id = try #require(model.selection)
		let kept = try #require(model.keepForUndo(id))

		#expect(model.restore(kept) == nil)
		#expect(model.notes.count == 1)
	}

	@Test func lockingForgetsTheKeptText() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["gone"])
		let id = try #require(model.selection)
		let kept = try #require(model.keepForUndo(id))
		await model.delete(id)

		await model.lock()
		#expect(model.restore(kept) == nil)
		await model.unlock(password: workspacePassword)

		#expect(model.restore(kept) == nil)
		#expect(model.notes.isEmpty)
	}

	@Test func deletingARestoredNoteBeforeItsSaveLandsLeavesNothingOnDisk() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["deleted twice"])
		let id = try #require(model.selection)
		let kept = try #require(model.keepForUndo(id))
		await model.delete(id)
		let restored = try #require(model.restore(kept))

		await model.delete(restored)
		#expect(await model.flushPendingSaves())

		let disk = try await observer(of: directory)
		#expect(try await disk.liveNotes().isEmpty)
		#expect(try await disk.pendingPushes().allSatisfy { $0.id != restored })
		await model.lock()
		await model.unlock(password: workspacePassword)
		#expect(model.notes.isEmpty)
	}

	@Test func undoRightAfterDeleteRestoresBeforeTheTombstoneLands() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["quick undo"])
		let id = try #require(model.selection)
		let kept = try #require(model.keepForUndo(id))

		let deleting = Task { await model.delete(id) }
		await Task.yield()
		let restored = model.restore(kept)
		_ = await deleting.value

		#expect(restored != nil)
		#expect(model.notes.map(\.body) == ["quick undo"])
	}

	@Test func aRestoredNoteJoinsASearchTypedAfterTheDelete() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kayak trip", "canoe trip", "kayak repair"])
		let deleted = try #require(model.notes.first { $0.body == "kayak trip" })
		let kept = try #require(model.keepForUndo(deleted.id))
		await model.delete(deleted.id)
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.flatMap(\.notes).map(\.body) == ["kayak repair"])

		let restored = try #require(model.restore(kept))
		try await settle { model.groups.flatMap(\.notes).count == 2 }

		#expect(Set(model.groups.flatMap(\.notes).map(\.body)) == ["kayak trip", "kayak repair"])
		#expect(model.groups.flatMap(\.notes).contains { $0.id == restored })
	}

	@Test func aRestoredNoteTakesItsPlaceInTheSearchResults() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kayak trip", "canoe trip", "kayak repair"])
		model.search = "kayak"
		await model.runSearch()
		let deleted = try #require(model.groups.flatMap(\.notes).first { $0.body == "kayak trip" })
		let kept = try #require(model.keepForUndo(deleted.id))
		await model.delete(deleted.id)

		let restored = try #require(model.restore(kept))

		#expect(Set(model.groups.flatMap(\.notes).map(\.body)) == ["kayak trip", "kayak repair"])
		#expect(model.groups.flatMap(\.notes).contains { $0.id == restored })
	}
}
