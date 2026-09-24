import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SavePathTests {
	private let alarm = Alarm()

	@Test func lockingRightAfterTypingKeepsTheEdit() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)

		model.edit(id, "typed then locked")
		await model.lock()
		await model.unlock(password: workspacePassword)

		#expect(model.notes.first { $0.id == id }?.body == "typed then locked")
	}

	@Test func lockingClosesTheDatabase() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		model.edit(try #require(model.selection), "typed then locked")

		await model.lock()

		#expect(!FileManager.default.fileExists(atPath: walFile(of: AppLock.databaseFile(in: directory)).path))
	}

	@Test func lockingWithEditsInTwoNotesSavesBoth() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let first = try #require(model.selection)
		await model.createNote()
		let second = try #require(model.selection)
		await model.createNote()

		model.edit(first, "first note")
		model.edit(second, "second note")
		await model.lock()

		#expect(model.failure == nil)
		let disk = try await observer(of: directory)
		#expect(try await disk.note(id: first)?.body == "first note")
		#expect(try await disk.note(id: second)?.body == "second note")
	}

	@Test func lockingWhileASaveIsInFlightKeepsTheNewerText() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)

		model.edit(id, "first")
		let saving = Task { await model.flushPendingSaves() }
		await Task.yield()
		model.edit(id, "first and more")
		await model.lock()
		_ = await saving.value

		#expect(model.failure == nil)
		#expect(try await observer(of: directory).note(id: id)?.body == "first and more")
	}

	@Test func leavingANoteSavesItAtOnce() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let first = try #require(model.selection)
		await model.createNote()
		let second = try #require(model.selection)

		model.selection = first
		model.edit(first, "alpha")
		model.selection = second
		model.edit(second, "beta")
		try await settle { try await disk.note(id: first)?.body == "alpha" }

		#expect(try await disk.note(id: first)?.body == "alpha")
		await model.flushPendingSaves()
		#expect(try await disk.note(id: second)?.body == "beta")
	}

	@Test func continuousTypingSavesWithoutAPause() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)

		var typed = ""
		for _ in 0 ..< 25 {
			typed += "a"
			model.edit(id, typed)
			await Task.yield()
		}
		await settle { await alarm.started >= 1 }
		await alarm.ring(number: 1)
		for _ in 0 ..< 25 {
			typed += "b"
			model.edit(id, typed)
			await Task.yield()
		}
		try await settle { try await disk.note(id: id)?.body.isEmpty == false }

		let saved = try #require(try await disk.note(id: id)?.body)
		#expect(!saved.isEmpty)
		#expect(typed.hasPrefix(saved))
		await model.flushPendingSaves()
	}

	@Test func typingDuringASaveIsNeverReverted() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)

		model.edit(id, "first")
		let saving = Task { await model.flushPendingSaves() }
		await Task.yield()
		model.edit(id, "first and more")
		_ = await saving.value

		#expect(model.selectedNote?.body == "first and more")
		await model.flushPendingSaves()
		#expect(try await disk.note(id: id)?.body == "first and more")
	}

	@Test func creatingANoteKeepsUnsavedTextInTheOthers() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let first = try #require(model.selection)

		model.edit(first, "typed, not yet saved")
		await model.createNote()

		#expect(model.notes.count == 2)
		#expect(model.notes.first { $0.id == first }?.body == "typed, not yet saved")
		await model.flushPendingSaves()
	}

	@Test func editsLandInTheNoteTheEditorShows() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let shown = try #require(model.selection)
		await model.createNote()
		let selected = try #require(model.selection)

		model.edit(shown, "typed into the note on screen")

		#expect(model.notes.first { $0.id == shown }?.body == "typed into the note on screen")
		#expect(model.notes.first { $0.id == selected }?.body == "")
		await model.flushPendingSaves()
	}

	@Test func editingWithTheSameTextSchedulesNothing() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		model.edit(id, "same")
		await model.flushPendingSaves()
		let before = model.selectedNote

		model.edit(id, "same")

		#expect(model.selectedNote == before)
		#expect(await model.flushPendingSaves())
		#expect(await alarm.started == 1)
	}

	@Test func editingANoteFromDiskMarksItDirtyWithoutBumpingVersionOrSeq() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		let created = Date(epochMilliseconds: 1_760_000_000_000)
		let seeded = Note(id: UUID(), body: "from sync", createdAt: created, updatedAt: created, v: 3, seq: 7)
		let seeding = try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: try await workspaceKey())
		try await seeding.save(seeded)
		await seeding.close()
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
		model.start()
		await model.unlock(password: workspacePassword)

		model.edit(seeded.id, "edited locally")
		await model.flushPendingSaves()

		let stored = try #require(try await observer(of: directory).note(id: seeded.id))
		#expect(stored.body == "edited locally")
		#expect(stored.dirty)
		#expect(stored.updatedAt > created)
		#expect(stored.createdAt == created)
		#expect(stored.v == 3)
		#expect(stored.seq == 7)
	}

	@Test func deletingWithASavePendingLeavesAnEmptyTombstone() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)

		model.edit(id, "secret\nbody")
		await model.deleteSelected()
		await model.flushPendingSaves()

		let tombstone = try #require(try await disk.note(id: id))
		#expect(tombstone.deleted)
		#expect(tombstone.body.isEmpty)
		#expect(!model.notes.contains { $0.id == id })
	}
}
