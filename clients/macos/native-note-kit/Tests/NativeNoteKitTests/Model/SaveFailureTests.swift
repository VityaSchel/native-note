import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SaveFailureTests {
	private let alarm = Alarm()

	private func poison(_ directory: URL) async throws {
		try await connection(to: directory).execute(
			"CREATE TRIGGER poison BEFORE UPDATE ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END"
		)
	}

	@Test func aFailedSaveIsRetried() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure == .unsaved("database is locked"))
		try blocker.execute("ROLLBACK")

		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed while the database was busy")
	}

	@Test func aFailingSaveIsReportedOnceWhileItRetries() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure?.isUnsaved == true)
		model.dismissFailure()
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure == nil)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())
		#expect(model.unsavedReason == nil)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while it was busy again")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure?.isUnsaved == true)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed while it was busy again")
	}

	@Test func theUnsavedAlertClearsOnceTheSaveLands() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure?.isUnsaved == true)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())

		#expect(model.failure == nil)
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
		#expect(await model.flushPendingSaves() == false)
		model.edit(healthy, "fine")
		await model.flushPendingSaves()
		#expect(try await observer(of: directory).note(id: healthy)?.body == "fine")
		#expect(model.failure == .unsaved("poisoned"))

		model.edit(poisoned, "cured")
		#expect(await model.flushPendingSaves())
		#expect(model.failure == nil)
		#expect(model.unsavedReason == nil)
	}

	@Test func aFailedDeleteKeepsTheLatestEdit() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)

		model.edit(id, "typed just before delete")
		try blocker.execute("BEGIN IMMEDIATE")
		await model.deleteSelected()
		try blocker.execute("ROLLBACK")
		await model.flushPendingSaves()

		#expect(model.notes.contains { $0.id == id })
		#expect(try await disk.note(id: id)?.body == "typed just before delete")
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

	@Test func lockingWithAFailingSaveShowsItOnTheLockScreen() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed then locked while busy")
		#expect(await model.flushPendingSaves() == false)
		model.dismissFailure()
		await model.lock()

		#expect(model.phase == .locked)
		#expect(model.failure?.isUnsaved == true)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed then locked while busy")
	}

	@Test func aStoreKeptOpenForAFailingSaveClosesOnceItLands() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		var blocker: SQLiteConnection? = try await connection(to: directory)

		try blocker?.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed then locked while busy")
		await model.lock()
		try blocker?.execute("ROLLBACK")
		blocker = nil
		#expect(await model.flushPendingSaves())

		#expect(!FileManager.default.fileExists(atPath: walFile(of: AppLock.databaseFile(in: directory)).path))
		#expect(try await observer(of: directory).note(id: id)?.body == "typed then locked while busy")
	}

	@Test func unlockingWhileASaveStillFailsKeepsTheTypedText() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		model.edit(id, "saved before")
		await model.flushPendingSaves()
		let blocker = try await connection(to: directory)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed then locked while busy")
		await model.lock()
		model.dismissFailure()
		await model.unlock(password: workspacePassword)

		#expect(model.phase == .unlocked)
		#expect(model.notes.first { $0.id == id }?.body == "typed then locked while busy")
		#expect(model.failure?.isUnsaved == true)
		#expect(await model.flushPendingSaves() == false)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed then locked while busy")
		#expect(model.notes.first { $0.id == id }?.body == "typed then locked while busy")
	}
}

private extension AppModel.Failure {
	var isUnsaved: Bool {
		if case .unsaved = self { true } else { false }
	}
}
