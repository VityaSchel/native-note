import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelTests {
	private let alarm = Alarm()

	@Test func walksSetUpEditLockAndUnlock() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast })

		model.start()
		#expect(model.phase == .needsSetup)

		await model.setUp(password: "correct horse")
		#expect(model.phase == .unlocked)
		#expect(model.notes.isEmpty)

		await model.createNote()
		#expect(model.notes.count == 1)
		let id = try #require(model.selection)

		model.edit(id, "Shopping\nquartz and bread")
		#expect(model.selectedNote?.title == "Shopping")

		await model.lock()
		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty)

		await model.unlock(password: "wrong horse")
		#expect(model.phase == .locked)
		#expect(model.failure == .wrongPassword)

		await model.unlock(password: "correct horse")
		#expect(model.phase == .unlocked)
		#expect(model.notes.map(\.id) == [id])
		#expect(model.notes.first?.body == "Shopping\nquartz and bread")
	}

	@Test func startsLockedWhenParametersAlreadyExist() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))

		let model = AppModel(directory: directory, makeParameters: { .fast })
		model.start()

		#expect(model.phase == .locked)
	}

	@Test func submitSetsUpOnFirstRunAndUnlocksAfterwards() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast })
		model.start()
		#expect(model.phase == .needsSetup)

		await model.submit(password: "correct horse")
		#expect(model.phase == .unlocked)
		await model.lock()

		await model.submit(password: "wrong horse")
		#expect(model.phase == .locked)
		#expect(model.failure == .wrongPassword)

		await model.submit(password: "correct horse")
		#expect(model.phase == .unlocked)
	}

	@Test func unlockingWithoutParametersSaysSo() async throws {
		let directory = temporaryDirectory()
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))

		await model.unlock(password: workspacePassword)

		#expect(model.phase != .unlocked)
		#expect(model.failure == .unexpected("No unlock parameters were found beside the notes database."))
	}

	@Test func parametersBoundToAnotherMacReportTheRefusal() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var foreign = UnlockParameters.fast
		foreign.enclaveKey = Data(repeating: 0x11, count: 8)
		try AppLock.write(foreign, to: AppLock.currentFile(in: directory))
		let refusal = try #require(#expect(throws: (any Error).self) { try MachineKey(representation: foreign.enclaveKey ?? Data()) })
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
		model.start()

		await model.unlock(password: workspacePassword)

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected(AppModel.Failure.reason(for: refusal)))
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
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try FileManager.default.createDirectory(at: AppLock.databaseFile(in: directory), withIntermediateDirectories: true)
		let model = AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep))
		model.start()

		await model.unlock(password: workspacePassword)

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("The notes database could not be opened. unable to open database file"))
	}

	@Test func lockingTwiceIsHarmless() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }

		await model.lock()
		await model.lock()

		#expect(model.phase == .locked)
		#expect(model.failure == nil)
	}

	@Test func deletingRemovesTheNoteFromTheList() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast })
		await model.setUp(password: "correct horse")
		await model.createNote()

		await model.deleteSelected()

		#expect(model.notes.isEmpty)
		#expect(model.selection == nil)
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

	@Test func aSelectionMissingFromTheListShowsNoNote() {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))

		model.selection = UUID()

		#expect(model.selectedNote == nil)
	}
}
