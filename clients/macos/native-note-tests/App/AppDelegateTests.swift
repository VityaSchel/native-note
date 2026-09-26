import AppKit
import Foundation
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppDelegateTests {
	private let alarm = Alarm()

	@Test func quittingWaitsForThePendingSave() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
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
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)
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

	@Test func quittingClosesTheLibrary() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		let sidecars = { try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") } }
		var replied: Bool?
		#expect(try !sidecars().isEmpty)

		_ = delegate.terminate { replied = $0 }
		await settle { replied != nil }

		#expect(replied == true)
		#expect(try sidecars().isEmpty)
	}

	@Test func cancellingTheQuitKeepsTheLibraryOpen() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.createNote()
		let id = try #require(model.selection)
		let blocker = try await connection(to: directory)
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		var replied: Bool?

		try blocker.execute("BEGIN IMMEDIATE")
		model.edit(id, "typed while the database was busy")
		_ = delegate.terminate { replied = $0 }
		await settle { replied != nil }
		try blocker.execute("ROLLBACK")

		#expect(replied == false)
		#expect(await model.flushPendingSaves())
		#expect(try await observer(of: directory).note(id: id)?.body == "typed while the database was busy")
	}

	private func lockedWithTouchID(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
		try await turnOnTouchID(model)
		await model.lock()
		return (model, directory)
	}

	@Test func returningToTheLockedAppOffersTouchID() async throws {
		let (model, directory) = try await lockedWithTouchID(FakeKeyStore())
		defer { try? FileManager.default.removeItem(at: directory) }
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		#expect(!model.offersBiometricUnlock)

		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

		#expect(model.offersBiometricUnlock)
	}

	@Test func theTouchIDPromptTakingFocusDoesNotAskAgain() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		let (answer, answered) = AsyncStream<Void>.makeStream()
		keys.reply(with: .cancel)
		keys.whileLoading {
			for await _ in answer { break }
		}

		let prompt = Task { await model.unlockWithBiometrics() }
		await settle { model.isPromptingBiometrics }
		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
		answered.yield()
		await prompt.value
		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
		#expect(!model.offersBiometricUnlock)

		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
		#expect(model.offersBiometricUnlock)
	}

	@Test func theQuitAlertOnlyQuitsOnAnExplicitClick() {
		let alert = AppDelegate.quitLosingEditsAlert("disk I/O error")

		#expect(alert.buttons.map(\.title) == ["Cancel", "Quit Anyway"])
		#expect(alert.buttons.map(\.keyEquivalent) == ["\u{1b}", ""])
		#expect(alert.buttons.last?.hasDestructiveAction == true)
		#expect(alert.informativeText.contains("disk I/O error"))
	}

	@Test func leavingTheAppSavesAtOnce() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
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
		let (model, directory) = try await unlockedModel(alarm: alarm)
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
