import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
	let model: AppModel
	private let confirmQuitLosingEdits: @MainActor (String) -> Bool

	init(model: AppModel, confirmQuitLosingEdits: @escaping @MainActor (String) -> Bool = AppDelegate.askToQuitLosingEdits) {
		self.model = model
		self.confirmQuitLosingEdits = confirmQuitLosingEdits
	}

	override convenience init() {
		self.init(model: AppModel())
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
		flushPendingSaves()
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		terminate { sender.reply(toApplicationShouldTerminate: $0) }
	}

	func terminate(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
		Task {
			await model.flushPendingSaves()
			guard let reason = model.unsavedReason else { return reply(true) }
			reply(confirmQuitLosingEdits(reason))
		}
		return .terminateLater
	}

	static func askToQuitLosingEdits(_ reason: String) -> Bool {
		quitLosingEditsAlert(reason).runModal() == .alertSecondButtonReturn
	}

	static func quitLosingEditsAlert(_ reason: String) -> NSAlert {
		let alert = NSAlert()
		alert.alertStyle = .warning
		alert.messageText = "Your latest edits couldn't be saved"
		alert.informativeText = [reason, "Quitting now loses them."].filter { !$0.isEmpty }.joined(separator: "\n\n")
		alert.addButton(withTitle: "Cancel")
		alert.addButton(withTitle: "Quit Anyway").hasDestructiveAction = true
		return alert
	}

	@objc private func flushPendingSaves() {
		Task { await model.flushPendingSaves() }
	}
}
