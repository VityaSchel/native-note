import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
	let model: AppModel

	init(model: AppModel) {
		self.model = model
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
			reply(true)
		}
		return .terminateLater
	}

	@objc private func flushPendingSaves() {
		Task { await model.flushPendingSaves() }
	}
}
