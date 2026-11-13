import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct LibraryEraseTests {
	private let alarm = Alarm()

	private var library: Workspace {
		Workspace(holding: ["Shopping", "Trip"]) { [alarm] directory, keys in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), makeParameters: { .fast }, keyStore: keys)
		}
	}

	private func remaining(in directory: URL) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
	}

	@Test func erasingLeavesNoTraceOfTheLibraryAndReturnsToSetup() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library.unlocked(keys)
		try await turnOnTouchID(model)
		for name in ["notes-set-aside-20260101T000000Z-1.db", "notes-set-aside-20260101T000000Z-1.db-wal"] {
			FileManager.default.createFile(atPath: directory.appending(path: name).path, contents: Data("old notes".utf8))
		}
		await model.lock()

		await model.eraseLibrary()

		#expect(model.phase == .needsSetup)
		#expect(model.failure == nil)
		#expect(try remaining(in: directory).isEmpty)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func aNewLibraryStartsEmptyAfterAnErase() async throws {
		let (model, _) = try await library.unlocked(FakeKeyStore())
		await model.lock()
		await model.eraseLibrary()

		await model.submit(password: "a fresh password")

		#expect(model.phase == .unlocked)
		#expect(model.notes.isEmpty)
		await model.lock()
		await model.submit(password: workspacePassword)
		#expect(model.failure == .wrongPassword)
	}

	@Test func erasingIsOnlyForTheLockScreen() async throws {
		let (model, directory) = try await library.unlocked(FakeKeyStore())

		await model.eraseLibrary()

		#expect(model.phase == .unlocked)
		#expect(model.notes.count == 2)
		#expect(FileManager.default.fileExists(atPath: AppLock.databaseFile(in: directory).path))
	}

	@Test func erasingWhileASaveKeepsFailingLeavesNothingBehind() async throws {
		let (model, directory) = try await library.unlocked(FakeKeyStore())
		try await connection(to: directory).execute(
			"CREATE TRIGGER poison BEFORE UPDATE ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END"
		)
		model.edit(try #require(model.notes.first?.id), "poison")
		#expect(await model.flushPendingSaves() == false)
		await model.lock()

		await model.eraseLibrary()
		await alarm.ring()
		try await settle { await alarm.sleeping == 0 }

		#expect(model.phase == .needsSetup)
		#expect(try remaining(in: directory).isEmpty)
		#expect(model.failure == nil)
		#expect(model.unsavedReason == nil)
		#expect(await model.flushPendingSaves())
	}

	@Test func erasingDuringARekeyRemovesBothParameterFiles() async throws {
		let (model, directory) = try await library.unlocked(FakeKeyStore())
		await model.lock()
		try AppLock.write(.fast, to: AppLock.pendingRekeyFile(in: directory))

		await model.eraseLibrary()

		#expect(AppLock.parameterFiles(in: directory).isEmpty)
		#expect(try remaining(in: directory).isEmpty)
	}

	@Test func anEraseThatCannotDeleteAFileSaysSoAndStillReachesSetup() async throws {
		let (model, directory) = try await library.unlocked(FakeKeyStore())
		let database = AppLock.databaseFile(in: directory)
		defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: database.path) }
		await model.lock()
		try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: database.path)

		await model.eraseLibrary()

		#expect(model.phase == .needsSetup)
		#expect(model.failure != nil)
		#expect(model.touchID == .hidden)
		#expect(AppLock.parameterFiles(in: directory).isEmpty)
	}

	@Test func editsInTheNewLibraryAreSaved() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library.unlocked(keys)
		await model.lock()
		await model.eraseLibrary()
		await model.submit(password: "a fresh password")
		await model.createNote()
		model.edit(try #require(model.selection), "written after the erase")
		await model.flushPendingSaves()
		await model.lock()

		let relaunched = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		relaunched.start()
		await relaunched.submit(password: "a fresh password")

		#expect(relaunched.notes.map(\.body) == ["written after the erase"])
	}

	@Test func aSaveStillRunningWhenTheEraseStartsLeavesNoAlertBehind() async throws {
		let (model, directory) = try await library.unlocked(FakeKeyStore())
		try await connection(to: directory).execute(
			"CREATE TRIGGER poison BEFORE UPDATE ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END"
		)
		model.edit(try #require(model.notes.first?.id), "poison")
		#expect(await model.flushPendingSaves() == false)
		await model.lock()

		let flushing = Task { await model.flushPendingSaves() }
		await model.eraseLibrary()
		_ = await flushing.value
		await alarm.ring()

		#expect(model.unsavedReason == nil)
		#expect(model.failure == nil)
		#expect(await model.flushPendingSaves())
		await model.submit(password: "a fresh password")
		#expect(model.failure == nil)
	}

	@Test func theErasedLibrarysSearchDoesNotFollowIntoTheNewOne() async throws {
		let (model, _) = try await library.unlocked(FakeKeyStore(), holding: ["bank pin 4711"])
		model.search = "bank pin"
		await model.runSearch()
		await model.lock()

		await model.eraseLibrary()
		await model.submit(password: "a fresh password")
		await model.createNote()

		#expect(model.search.isEmpty)
		#expect(model.groups.flatMap(\.notes).count == 1)
	}
}
