import AppKit
import LocalAuthenticationEmbeddedUI

@testable import NativeNoteKit

@MainActor
final class Sensor {
	private let finger = Latch()
	private(set) var readsThroughAGlyphInTheWindow: [Bool] = []

	var isWaiting: Bool {
		finger.isHolding
	}

	func watch(_ keys: FakeKeyStore, in windows: NSWindow...) {
		keys.whileLoading { @MainActor in
			let context = keys.contexts.last
			let shown = windows.flatMap { [$0] + $0.sheets }
			let glyphs = shown.compactMap(\.contentView).flatMap(Self.glyphs(in:))
			self.readsThroughAGlyphInTheWindow.append(glyphs.contains { $0.context === context && $0.window.map(shown.contains) == true })
			await self.finger.wait()
		}
	}

	func touch() {
		finger.release()
	}

	private static func glyphs(in root: NSView) -> [LAAuthenticationView] {
		var found: [LAAuthenticationView] = []
		var pending = [root]
		while let view = pending.popLast() {
			if let glyph = view as? LAAuthenticationView { found.append(glyph) }
			pending.append(contentsOf: view.subviews)
		}
		return found
	}
}
