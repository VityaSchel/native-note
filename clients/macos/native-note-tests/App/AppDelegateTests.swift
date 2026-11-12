import AppKit
import Foundation
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppDelegateTests {
	private let alarm = Alarm()
	private let shaking = Alarm()

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
		let (model, directory) = try await unlockedModel { [alarm, shaking] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys, shakeTimer: shaking.sleep)
		}
		try await turnOnTouchID(model)
		await model.lock()
		return (model, directory)
	}

	@Test func leavingTheLockedAppStopsTouchIDAndReturningListensAgain() async throws {
		let (model, directory) = try await lockedWithTouchID(FakeKeyStore())
		defer { try? FileManager.default.removeItem(at: directory) }
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		let listening = try #require(model.touchID.listeningContext)

		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(listening))

		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

		let fresh = try #require(model.touchID.listeningContext)
		#expect(fresh !== listening)
		#expect(!isInvalidated(fresh))
	}

	@Test func aLibraryThatOpensLockedListensOnceTheAppIsActive() async throws {
		let keys = FakeKeyStore()
		let (_, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let relaunched = AppModel(directory: directory, keyStore: keys)
		let delegate = AppDelegate(model: relaunched, confirmQuitLosingEdits: QuitPrompt().ask)
		relaunched.start()

		#expect(relaunched.touchID == .paused(.inBackground))

		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

		#expect(relaunched.touchID.listeningContext != nil)
	}

	@Test func aMissShakesThroughALeaveAndReturnThenListensAgain() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask)
		keys.reply(with: .miss)
		try #require(await touch(model))

		delegate.applicationWillResignActive(Notification(name: NSApplication.willResignActiveNotification))
		delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))

		#expect(model.touchID == .paused(.shaking))
		await ring(shaking)
		await settle { !model.shake.isRunning }
		let fresh = try #require(model.touchID.listeningContext)
		#expect(fresh !== keys.contexts.first)
		#expect(!isInvalidated(fresh))
	}

	@Test func clickingTheDockIconWithNoWindowOpenBringsTheLibraryWindowBack() {
		let delegate = AppDelegate(model: .previewing([]), confirmQuitLosingEdits: QuitPrompt().ask)
		#expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
		var shown = 0
		delegate.exchange.showWindow = { shown += 1 }

		#expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
		#expect(shown == 0)
		#expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
		#expect(shown == 1)
		#expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
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

	@Test func sleepingSavesAndLocks() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let disk = try await observer(of: directory)
		await model.createNote()
		let id = try #require(model.selection)
		let workspace = NotificationCenter()
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask, workspace: workspace)
		delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

		model.edit(id, "typed then slept")
		workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
		try await settle { try await disk.note(id: id)?.body == "typed then slept" }

		#expect(try await disk.note(id: id)?.body == "typed then slept")
		await settle { model.phase == .locked }
		#expect(model.phase == .locked)
	}

	@Test func aLockedScreenOrAnotherUsersSessionLocksTheLibrary() async throws {
		for away in ["screen", "session"] {
			let (model, directory) = try await unlockedModel(alarm: alarm)
			defer { try? FileManager.default.removeItem(at: directory) }
			let workspace = NotificationCenter()
			let notice = Self.privateScreenLockNotice()
			let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask, workspace: workspace, screenLocked: notice)
			delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

			if away == "screen" {
				#expect(await Self.postAndAwaitArrival(notice))
			} else {
				workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
			}
			await settle { model.phase == .locked }

			#expect(model.phase == .locked, "\(away)")
		}
	}

	@Test func goingAwayBeforeSetupLeavesTheFirstRunAlone() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(libraryAt: directory)
		model.start()
		let notice = Self.privateScreenLockNotice()
		let delegate = AppDelegate(model: model, confirmQuitLosingEdits: QuitPrompt().ask, workspace: NotificationCenter(), screenLocked: notice)
		delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))

		#expect(await Self.postAndAwaitArrival(notice))

		#expect(model.phase == .needsSetup)
	}
}

extension AppDelegateTests {
	static func privateScreenLockNotice() -> Notification.Name {
		Notification.Name("dev.hloth.nativenote.tests.screen-locked.\(UUID().uuidString)")
	}

	static func postAndAwaitArrival(_ notice: Notification.Name) async -> Bool {
		let center = DistributedNotificationCenter.default()
		let arrival = Arrival()
		let token = center.addObserver(forName: notice, object: nil, queue: nil) { _ in
			MainActor.assumeIsolated { arrival.arrived = true }
		}
		defer { center.removeObserver(token) }
		center.post(name: notice, object: nil)
		for _ in 0 ..< 500 where !arrival.arrived {
			turnRunLoop()
			await Task.yield()
		}
		return arrival.arrived
	}

	private static func turnRunLoop() {
		RunLoop.current.run(until: Date().addingTimeInterval(0.01))
	}
}

@MainActor private final class Arrival {
	var arrived = false
}

@MainActor private final class QuitPrompt {
	var reasons: [String] = []
	var quitAnyway = false

	func ask(_ reason: String) -> Bool {
		reasons.append(reason)
		return quitAnyway
	}
}
