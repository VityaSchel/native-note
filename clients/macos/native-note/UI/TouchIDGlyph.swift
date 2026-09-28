import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

struct TouchIDGlyph: NSViewRepresentable {
	enum Mode {
		case listening(LAContext)
		case dimmed
	}

	let mode: Mode
	let label: String?
	var size = NSControl.ControlSize.regular
	var listen: (LAAuthenticationView) async -> Void = { _ in }

	func makeNSView(context: Context) -> TouchIDGlyphView {
		TouchIDGlyphView()
	}

	func updateNSView(_ view: TouchIDGlyphView, context: Context) {
		view.listen = listen
		view.size = size
		view.show(mode, label: label)
	}
}

final class TouchIDGlyphView: NSView {
	static let side: CGFloat = 64

	var listen: (LAAuthenticationView) async -> Void = { _ in }
	var size = NSControl.ControlSize.regular
	private(set) var paired: LAAuthenticationView?
	private(set) var symbol: NSImageView?

	func show(_ mode: TouchIDGlyph.Mode, label: String?) {
		switch mode {
		case let .listening(context):
			if paired?.context !== context { pair(with: context) }
			paired?.setAccessibilityElement(label != nil)
			paired?.setAccessibilityLabel(label)
		case .dimmed:
			if symbol == nil { dim() }
		}
	}

	override func viewWillMove(toWindow newWindow: NSWindow?) {
		if newWindow == nil, window != nil { paired?.context.invalidate() }
		super.viewWillMove(toWindow: newWindow)
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		startListening()
	}

	private func pair(with context: LAContext) {
		clear()
		let glyph = LAAuthenticationView(context: context, controlSize: size)
		glyph.setAccessibilityRole(.image)
		place(glyph)
		paired = glyph
		startListening()
	}

	private func dim() {
		clear()
		let image = NSImageView(image: NSImage(systemSymbolName: "touchid", accessibilityDescription: nil) ?? NSImage())
		image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.side, weight: .ultraLight)
		image.contentTintColor = .tertiaryLabelColor
		image.setAccessibilityElement(false)
		place(image)
		symbol = image
	}

	private func place(_ view: NSView) {
		view.translatesAutoresizingMaskIntoConstraints = false
		addSubview(view)
		NSLayoutConstraint.activate([
			view.centerXAnchor.constraint(equalTo: centerXAnchor),
			view.centerYAnchor.constraint(equalTo: centerYAnchor),
		])
	}

	private func clear() {
		paired?.context.invalidate()
		paired?.removeFromSuperview()
		paired = nil
		symbol?.removeFromSuperview()
		symbol = nil
	}

	private func startListening() {
		guard let paired, window != nil else { return }
		let listen = listen
		Task { await listen(paired) }
	}
}
