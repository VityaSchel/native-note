import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelRuleTests {
	private let alarm = Alarm()

	private func poison(_ directory: URL) async throws {
		try await connection(to: directory).execute(
			"CREATE TRIGGER poison BEFORE UPDATE ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END"
		)
	}

	@Test func editingANoteFromDiskMarksItDirtyWithoutBumpingVersionOrSeq() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		let created = Date(epochMilliseconds: 1_760_000_000_000)
		let seeded = Note(id: UUID(), body: "from sync", createdAt: created, updatedAt: created, v: 3, seq: 7)
		let seeding = try await NoteStore.open(url: AppLock.database(in: directory), key: try await workspaceKey())
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

	@Test func aNoteSpecificFailureIsReportedWithItsReason() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		try await poison(directory)

		model.edit(id, "poison")

		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure == .unsaved("poisoned"))
		#expect(model.unsavedReason == "poisoned")
	}

	@Test func oneNoteLandingWhileAnotherStillFailsKeepsTheFailure() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let poisoned = try #require(model.selection)
		await model.createNote()
		let healthy = try #require(model.selection)
		try await poison(directory)

		model.edit(poisoned, "poison")
		model.edit(healthy, "fine")
		await model.flushPendingSaves()
		#expect(model.failure == .unsaved("poisoned"))

		model.edit(poisoned, "cured")
		#expect(await model.flushPendingSaves())
		#expect(model.failure == nil)
		#expect(model.unsavedReason == nil)
	}

	@Test func deletingANoteWhoseSaveKeepsFailingClearsTheFailure() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		try await poison(directory)
		model.edit(id, "poison")
		await model.flushPendingSaves()

		await model.deleteSelected()
		await model.flushPendingSaves()

		#expect(!model.notes.contains { $0.id == id })
		#expect(model.unsavedReason == nil)
		#expect(model.failure == nil)
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

	@Test func aFailedCreateAddsNothingAndSaysWhy() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let blocker = try await connection(to: directory)
		try blocker.execute("BEGIN IMMEDIATE")

		await model.createNote()
		try blocker.execute("ROLLBACK")

		#expect(model.notes.isEmpty)
		#expect(model.selection == nil)
		#expect(model.failure == .unexpected("database is locked"))
	}

	@Test func deletingWithNothingSelectedDoesNothing() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		model.selection = nil

		await model.deleteSelected()

		#expect(model.notes.count == 1)
		#expect(model.failure == nil)
	}

	@Test func lockingTwiceIsHarmless() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }

		await model.lock()
		await model.lock()

		#expect(model.phase == .locked)
		#expect(model.failure == nil)
	}

	@Test func searchingWhileLockedDoesNothing() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure == nil)
	}

	@Test func aSelectionMissingFromTheListShowsNoNote() {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))

		model.selection = UUID()

		#expect(model.selectedNote == nil)
	}

	@Test func previewEditsStayInMemory() throws {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
		let id = try #require(model.selection)

		model.edit(id, "changed in the canvas")

		#expect(model.selectedNote?.body == "changed in the canvas")
	}

	@Test func unlockingWithoutParametersSaysSo() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))

		await model.unlock(password: workspacePassword)

		#expect(model.phase != .unlocked)
		#expect(model.failure == .unexpected("No unlock parameters were found beside the notes database."))
	}

	@Test func aDatabaseFromANewerVersionAsksForAnUpdate() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()
		try await connection(to: directory).execute("PRAGMA user_version = 99")

		await model.unlock(password: workspacePassword)

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("The notes database was written by a newer version of Native Note. Update the app to open it."))
	}

	@Test func aDatabaseThatCannotBeOpenedSaysWhy() async throws {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try FileManager.default.createDirectory(at: AppLock.database(in: directory), withIntermediateDirectories: true)
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
		model.start()

		await model.unlock(password: workspacePassword)

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("The notes database could not be opened. unable to open database file"))
	}
}
