import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SavePathTests {
	private let password = "correct horse"
	private let alarm = Alarm()
	private let parameters = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.Parameters(m: 1024, t: 1, p: 1),
		enclaveKey: nil
	)

	private func unlockedModel() async throws -> (AppModel, URL) {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
		try AppLock.write(parameters, to: AppLock.current(in: directory))
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
		model.start()
		await model.unlock(password: password)
		try #require(model.phase == .unlocked)
		return (model, directory)
	}

	private func rawKey() async throws -> Data {
		try await Task.detached { [password, parameters] in
			try Unlock.localDbKey(password: password, parameters: parameters)
		}.value
	}

	private func observer(of directory: URL) async throws -> NoteStore {
		try await Unlock.open(password: password, database: directory.appending(path: "notes.db"), in: directory)
	}

	@Test func lockingRightAfterTypingKeepsTheEdit() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)

		model.edit(id, "typed then locked")
		await model.lock()
		await model.unlock(password: password)

		#expect(model.notes.first { $0.id == id }?.body == "typed then locked")
	}

	@Test func lockingClosesTheDatabase() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		model.edit(try #require(model.selection), "typed then locked")

		await model.lock()

		#expect(!FileManager.default.fileExists(atPath: directory.appending(path: "notes.db-wal").path))
	}

	@Test func lockingWithEditsInTwoNotesSavesBoth() async throws {
		let (model, directory) = try await unlockedModel()
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
		let (model, directory) = try await unlockedModel()
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

	@Test func aStoreKeptOpenForAFailingSaveClosesOnceItLands() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		var blocker: SQLiteConnection? = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

		try blocker?.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed then locked while busy")
		await model.lock()
		try blocker?.execute("ROLLBACK")
		blocker = nil
		#expect(await model.flushPendingSaves())

		#expect(!FileManager.default.fileExists(atPath: directory.appending(path: "notes.db-wal").path))
		#expect(try await observer(of: directory).note(id: id)?.body == "typed then locked while busy")
	}

	@Test func leavingANoteSavesItAtOnce() async throws {
		let (model, directory) = try await unlockedModel()
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
		let (model, directory) = try await unlockedModel()
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
		let (model, directory) = try await unlockedModel()
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
		let (model, directory) = try await unlockedModel()
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
		let (model, directory) = try await unlockedModel()
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

	@Test func aFailedSaveIsRetried() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure != nil)
		try blocker.execute("ROLLBACK")

		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed while the database was busy")
	}

	@Test func aFailedDeleteKeepsTheLatestEdit() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

		model.edit(id, "typed just before delete")
		try blocker.execute("BEGIN IMMEDIATE")
		await model.deleteSelected()
		try blocker.execute("ROLLBACK")
		await model.flushPendingSaves()

		#expect(model.notes.contains { $0.id == id })
		#expect(try await disk.note(id: id)?.body == "typed just before delete")
	}

	@Test func aFailingSaveIsReportedOnceWhileItRetries() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

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
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		#expect(await model.flushPendingSaves() == false)
		#expect(model.failure?.isUnsaved == true)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())

		#expect(model.failure == nil)
	}

	@Test func lockingClearsALibraryFailure() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		).execute("DROP TABLE note_fts")
		model.search = "kayak"
		await model.runSearch()
		try #require(model.failure != nil)

		await model.lock()

		#expect(model.failure == nil)
	}

	@Test func lockingWithAFailingSaveShowsItOnTheLockScreen() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

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

	@Test func unlockingWhileASaveStillFailsKeepsTheTypedText() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		model.edit(id, "saved before")
		await model.flushPendingSaves()
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed then locked while busy")
		await model.lock()
		model.dismissFailure()
		await model.unlock(password: password)

		#expect(model.phase == .unlocked)
		#expect(model.notes.first { $0.id == id }?.body == "typed then locked while busy")
		#expect(model.failure?.isUnsaved == true)
		#expect(await model.flushPendingSaves() == false)
		try blocker.execute("ROLLBACK")
		#expect(await model.flushPendingSaves())
		#expect(try await disk.note(id: id)?.body == "typed then locked while busy")
		#expect(model.notes.first { $0.id == id }?.body == "typed then locked while busy")
	}

	@Test func aFailedSearchReportsTheErrorAndShowsNothing() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		model.edit(try #require(model.selection), "kayak")
		await model.flushPendingSaves()
		try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		).execute("DROP TABLE note_fts")

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure?.isUnexpected == true)
	}

	@Test func aFailingSearchIsReportedOnceWhileTheUserTypes() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		).execute("DROP TABLE note_fts")

		var reports = 0
		for query in ["k", "ka", "kay", "kaya", "kayak"] {
			model.search = query
			await model.runSearch()
			if model.failure != nil { reports += 1 }
			model.dismissFailure()
		}
		model.search = ""
		await model.runSearch()
		model.search = "k"
		await model.runSearch()

		#expect(reports == 1)
		#expect(model.failure != nil)
	}

	@Test func deletingWithASavePendingLeavesAnEmptyTombstone() async throws {
		let (model, directory) = try await unlockedModel()
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

private extension AppModel.Failure {
	var isUnsaved: Bool {
		if case .unsaved = self { true } else { false }
	}

	var isUnexpected: Bool {
		if case .unexpected = self { true } else { false }
	}
}
