import AppKit
import SwiftUI

@MainActor
final class OffscreenWindow<Content: View> {
	let window: NSWindow
	let host: NSHostingView<Content>

	init(_ view: Content, width: CGFloat = 380, height: CGFloat = 620) {
		window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: width, height: height),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		host = NSHostingView(rootView: view)
		host.frame = NSRect(x: 0, y: 0, width: width, height: height)
		window.contentView = host
		pump(for: 0.05)
	}

	func pump(for interval: TimeInterval = 0.005) {
		window.layoutIfNeeded()
		host.layoutSubtreeIfNeeded()
		host.displayIfNeeded()
		RunLoop.current.run(until: Date().addingTimeInterval(interval))
	}

	func pump(turns: Int = 400, until done: () async throws -> Bool) async rethrows {
		for _ in 0 ..< turns {
			if try await done() { return }
			pump()
			await Task.yield()
		}
	}

	func views<View: NSView>(of type: View.Type) -> [View] {
		var found: [View] = []
		var pending: [NSView] = [host]
		while let view = pending.popLast() {
			if let match = view as? View { found.append(match) }
			pending.append(contentsOf: view.subviews)
		}
		return found
	}

	func close() {
		window.contentView = nil
		pump()
	}
}
