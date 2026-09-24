import AppKit
import Foundation
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppDelegateTests {
	private let password = "correct horse"
	private let parameters = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.Parameters(m: 1024, t: 1, p: 1),
		enclaveKey: nil
	)

	private func unlockedModel() async throws -> (AppModel, URL) {
		let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
		try AppLock.write(parameters, to: AppLock.current(in: directory))
		let model = AppModel(directory: directory, scheduler: SaveScheduler(delay: .seconds(3600)))
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


	@Test func quittingWaitsForThePendingSave() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let prompt = QuitPrompt()
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: prompt.ask)
		var replied: Bool?

		model.edit(id, "typed then quit")
		#expect(delegate.terminate { replied = $0 } == .terminateLater)
		await settle { replied != nil }

		#expect(replied == true)
		#expect(prompt.reasons.isEmpty)
		#expect(try await disk.note(id: id)?.body == "typed then quit")
	}

	@Test func quittingWithEditsThatCannotBeSavedAsksFirst() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try SQLiteConnection(
			url: directory.appending(path: "notes.db"),
			rawKey: try await rawKey()
		)
		let prompt = QuitPrompt()
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: prompt.ask)
		var replied: Bool?

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		_ = delegate.terminate { replied = $0 }
		await settle { replied != nil }
		#expect(replied == false)
		#expect(prompt.reasons.count == 1)
		#expect(prompt.reasons.first?.isEmpty == false)

		prompt.quitAnyway = true
		replied = nil
		_ = delegate.terminate { replied = $0 }
		await settle { replied != nil }
		#expect(replied == true)
		#expect(prompt.reasons.count == 2)
		try blocker.execute("ROLLBACK")
	}

	@Test func theQuitAlertOnlyQuitsOnAnExplicitClick() {
		let alert = AppDelegate.quitLosingEditsAlert("disk I/O error")

		#expect(alert.buttons.map(\.title) == ["Cancel", "Quit Anyway"])
		#expect(alert.buttons.map(\.keyEquivalent) == ["\u{1b}", ""])
		#expect(alert.buttons.last?.hasDestructiveAction == true)
		#expect(alert.informativeText.contains("disk I/O error"))
	}

	@Test func leavingTheAppSavesAtOnce() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)

		model.edit(id, "typed then switched apps")
		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
		try await settle { try await disk.note(id: id)?.body == "typed then switched apps" }

		#expect(try await disk.note(id: id)?.body == "typed then switched apps")
	}

	@Test func sleepingSavesAtOnce() async throws {
		let (model, directory) = try await unlockedModel()
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

		model.edit(id, "typed then slept")
		NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
		try await settle { try await disk.note(id: id)?.body == "typed then slept" }

		#expect(try await disk.note(id: id)?.body == "typed then slept")
	}
}

@MainActor private final class QuitPrompt {
	var reasons: [String] = []
	var quitAnyway = false

	func ask(_ reason: String) -> Bool {
		reasons.append(reason)
		return quitAnyway
	}
}

private func settle(until done: () async throws -> Bool) async rethrows {
	for _ in 0 ..< 10_000 {
		if try await done() { return }
		await Task.yield()
	}
}
