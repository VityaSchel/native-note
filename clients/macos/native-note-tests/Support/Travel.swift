import AppKit
import SwiftUI

@MainActor
final class Travel<Content: View>: NSObject {
	private let field: NSView
	private let offscreen: OffscreenWindow<Content>
	private let rest: NSRect
	private var moving: [NSView] = []
	private(set) var offsets: [(dx: CGFloat, dy: CGFloat)] = []

	init(of field: NSView, in offscreen: OffscreenWindow<Content>) {
		self.field = field
		self.offscreen = offscreen
		rest = offscreen.onScreen(field)
		super.init()
		moving = Array(sequence(first: field, next: \.superview).prefix { $0 !== offscreen.host })
		for view in moving {
			view.postsFrameChangedNotifications = true
			NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSView.frameDidChangeNotification, object: view)
		}
	}

	func offset() -> (dx: CGFloat, dy: CGFloat) {
		let now = offscreen.onScreen(field)
		return (now.minX - rest.minX, now.minY - rest.minY)
	}

	func stop() {
		NotificationCenter.default.removeObserver(self)
	}

	@objc private func moved(_ notification: Notification) {
		offsets.append(offset())
	}
}
