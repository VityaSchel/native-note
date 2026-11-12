import AppKit
import NativeNoteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
	let model: AppModel
	let exchange: LibraryExchange
	private let confirmQuitLosingEdits: @MainActor (String) -> Bool
	private let workspace: NotificationCenter
	private let screenLocked: Notification.Name

	init(
		model: AppModel,
		confirmQuitLosingEdits: @escaping @MainActor (String) -> Bool = AppDelegate.askToQuitLosingEdits,
		workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
		screenLocked: Notification.Name = Notification.Name("com.apple.screenIsLocked")
	) {
		self.model = model
		exchange = LibraryExchange(model: model)
		self.confirmQuitLosingEdits = confirmQuitLosingEdits
		self.workspace = workspace
		self.screenLocked = screenLocked
	}

	override convenience init() {
		self.init(model: Self.hostsTests ? AppModel(libraryAt: Self.testHostLibrary) : AppModel())
	}

	static let testHostLibrary = FileManager.default.temporaryDirectory.appending(path: "test-host-library")

	static var hostsTests: Bool {
		#if DEBUG
			ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
		#else
			false
		#endif
	}

	@objc private func tidyMenus(_ notification: Notification) {
		guard let menu = notification.object as? NSMenu, menu === NSApp.mainMenu else { return }
		MenuSeparators.hideDoubledAndEdgeSeparators(in: menu)
	}

	func applicationWillFinishLaunching(_ notification: Notification) {
		if Self.hostsTests {
			NSApp.setActivationPolicy(.prohibited)
		}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NotificationCenter.default.addObserver(self, selector: #selector(tidyMenus), name: NSMenu.didBeginTrackingNotification, object: nil)
		for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
			workspace.addObserver(self, selector: #selector(lockWhileAway), name: name, object: nil)
		}
		DistributedNotificationCenter.default().addObserver(
			self, selector: #selector(lockWhileAway), name: screenLocked, object: nil, suspensionBehavior: .deliverImmediately
		)
	}

	@objc private func lockWhileAway() {
		model.lockWhileAway()
	}

	func applicationWillResignActive(_ notification: Notification) {
		model.appResignedActive()
		flushPendingSaves()
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		model.appBecameActive()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		guard !hasVisibleWindows, let showWindow = exchange.showWindow else { return true }
		showWindow()
		return false
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		terminate { sender.reply(toApplicationShouldTerminate: $0) }
	}

	func terminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
		Task {
			await model.flushPendingSaves()
			if let reason = model.unsavedReason, !confirmQuitLosingEdits(reason) { return reply(false) }
			await model.close()
			RecoveryClipboard.shared.clear()
			reply(true)
		}
		return .terminateLater
	}

	private static func askToQuitLosingEdits(_ reason: String) -> Bool {
		quitLosingEditsAlert(reason).runModal() == .alertSecondButtonReturn
	}

	static func quitLosingEditsAlert(_ reason: String) -> NSAlert {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = "Your latest edits could not be saved."
		alert.informativeText = "If you quit now, these edits will be lost.\n\n\(reason)"
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
		return alert
	}

	@objc private func flushPendingSaves() {
		Task { await model.flushPendingSaves() }
	}
}
