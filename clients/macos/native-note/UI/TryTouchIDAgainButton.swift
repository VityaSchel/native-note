import AppKit
import SwiftUI

struct TryTouchIDAgainButton: NSViewRepresentable {
	static let title = "Try Touch ID Again"

	let action: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSButton {
		let button = NSButton(
			title: Self.title,
			image: NSImage(systemSymbolName: "touchid", accessibilityDescription: nil) ?? NSImage(),
			target: context.coordinator,
			action: #selector(Coordinator.click)
		)
		button.bezelStyle = .glass
		button.imagePosition = .imageLeading
		button.imageHugsTitle = true
		return button
	}

	func updateNSView(_ button: NSButton, context: Context) {
		context.coordinator.action = action
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton, context: Context) -> CGSize? {
		button.intrinsicContentSize
	}

	final class Coordinator: NSObject {
		var action: () -> Void = {}

		@objc func click() {
			action()
		}
	}
}
