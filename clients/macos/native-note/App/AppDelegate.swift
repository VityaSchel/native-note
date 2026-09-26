import AppKit
import NativeNoteKit

final class AppDelegate: NSObject, NSApplicationDelegate {
	let model: AppModel
	let exchange: LibraryExchange
	private let confirmQuitLosingEdits: @MainActor (String) -> Bool
	private var returningFromTouchID = false

	init(model: AppModel, confirmQuitLosingEdits: @escaping @MainActor (String) -> Bool = AppDelegate.askToQuitLosingEdits) {
		self.model = model
		exchange = LibraryExchange(model: model)
		self.confirmQuitLosingEdits = confirmQuitLosingEdits
	}

	override convenience init() {
		self.init(model: Self.hostsTests ? AppModel(libraryAt: Self.testHostLibrary) : AppModel())
	}

	static let testHostLibrary = FileManager.default.temporaryDirectory.appending(path: "test-host-library")

	private static var hostsTests: Bool {
		ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
	}

	func applicationWillFinishLaunching(_ notification: Notification) {
		if Self.hostsTests {
			NSApp.setActivationPolicy(.prohibited)
		}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSWorkspace.shared.notificationCenter.addObserver(
			self,
			selector: #selector(flushPendingSaves),
			name: NSWorkspace.willSleepNotification,
			object: nil
		)
	}

	func applicationWillResignActive(_ notification: Notification) {
		returningFromTouchID = model.isPromptingBiometrics
		flushPendingSaves()
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		guard !returningFromTouchID else {
			returningFromTouchID = false
			return
		}
		model.offerBiometricUnlock()
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		terminate { sender.reply(toApplicationShouldTerminate: $0) }
	}

	func terminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
		Task {
			await model.flushPendingSaves()
			if let reason = model.unsavedReason, !confirmQuitLosingEdits(reason) { return reply(false) }
			await model.close()
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
