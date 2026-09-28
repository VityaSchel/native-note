import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
struct TouchIDGlyphTests {
	private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 128, height: 128), styleMask: [.borderless], backing: .buffered, defer: true)
	private let heard = Heard()

	private func glyph() -> TouchIDGlyphView {
		let view = TouchIDGlyphView()
		view.listen = { [heard] in heard.glyphs.append($0) }
		return view
	}

	@Test func aGlyphListensOnlyOnceItIsInAWindow() async throws {
		let context = LAContext()
		let view = glyph()

		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)
		await settle { !heard.glyphs.isEmpty }
		#expect(heard.glyphs.isEmpty)
		#expect(view.paired?.context === context)

		window.contentView = view
		await settle { !heard.glyphs.isEmpty }

		#expect(heard.glyphs.count == 1)
		#expect(heard.glyphs.first === view.paired)
		#expect(heard.glyphs.first?.context === context)
		#expect(heard.glyphs.first?.window === window)
		#expect(view.paired?.accessibilityLabel() == TurnOnTouchIDView.touchIDLabel)
		#expect(!isInvalidated(context))
	}

	@Test func theSameAttemptKeepsItsGlyph() async throws {
		let context = LAContext()
		let view = glyph()
		window.contentView = view
		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)
		let paired = try #require(view.paired)

		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)
		await settle { heard.glyphs.count > 1 }

		#expect(view.paired === paired)
		#expect(heard.glyphs.count == 1)
	}

	@Test func aNewAttemptGetsANewGlyphAndEndsTheOldOne() async throws {
		let first = LAContext()
		let second = LAContext()
		let view = glyph()
		window.contentView = view
		view.show(.listening(first), label: TurnOnTouchIDView.touchIDLabel)

		view.show(.listening(second), label: TurnOnTouchIDView.touchIDLabel)
		await settle { heard.glyphs.count == 2 }

		#expect(view.paired?.context === second)
		#expect(view.subviews.count == 1)
		#expect(heard.glyphs.map(\.context) == [first, second])
		#expect(isInvalidated(first))
		#expect(!isInvalidated(second))
	}

	@Test func leavingTheWindowEndsTheAttempt() async throws {
		let context = LAContext()
		let view = glyph()
		window.contentView = view
		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)

		window.contentView = nil

		#expect(isInvalidated(context))
	}

	@Test func aGlyphThatNeverReachedAWindowEndsNothing() {
		let context = LAContext()
		let holder = NSView()
		let view = glyph()
		holder.addSubview(view)
		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)

		view.removeFromSuperview()

		#expect(!isInvalidated(context))
	}

	@Test func dimmingEndsTheAttemptAndShowsTheSymbol() async throws {
		let context = LAContext()
		let view = glyph()
		window.contentView = view
		view.show(.listening(context), label: TurnOnTouchIDView.touchIDLabel)

		view.show(.dimmed, label: TurnOnTouchIDView.touchIDLabel)

		#expect(view.paired == nil)
		#expect(view.symbol?.contentTintColor == .tertiaryLabelColor)
		#expect(view.subviews.count == 1)
		#expect(isInvalidated(context))
	}

	@Test func aGlyphWithoutALabelIsHiddenFromAccessibility() {
		let labelled = glyph()
		labelled.show(.listening(LAContext()), label: TurnOnTouchIDView.touchIDLabel)
		let unlabelled = glyph()
		unlabelled.show(.listening(LAContext()), label: nil)

		#expect(labelled.paired?.isAccessibilityElement() == true)
		#expect(labelled.paired?.accessibilityRole() == .image)
		#expect(unlabelled.paired?.isAccessibilityElement() == false)
		#expect(unlabelled.paired?.accessibilityLabel() == nil)
	}

	@Test func aGlyphPairsAtItsControlSize() throws {
		let regular = glyph()
		regular.show(.listening(LAContext()), label: nil)
		let mini = glyph()
		mini.size = .mini
		mini.show(.listening(LAContext()), label: nil)

		#expect(try #require(regular.paired).fittingSize == NSSize(width: TouchIDGlyphView.side, height: TouchIDGlyphView.side))
		#expect(try #require(mini.paired).fittingSize == NSSize(width: UnlockView.coveredGlyphSide, height: UnlockView.coveredGlyphSide))
	}
}

@MainActor
private final class Heard {
	var glyphs: [LAAuthenticationView] = []
}
