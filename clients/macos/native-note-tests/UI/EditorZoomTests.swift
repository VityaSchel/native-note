import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct EditorZoomTests {
	@Test func zoomStepsStayWithinTheirRange() {
		#expect(EditorZoom.larger(1) == 1.2)
		#expect(EditorZoom.smaller(1) == 0.83)
		#expect(EditorZoom.larger(2.9) == 3)
		#expect(EditorZoom.smaller(0.55) == 0.5)
	}

	@Test func theEditorTakesTheMagnification() throws {
		let offscreen = OffscreenWindow(NoteEditor(text: .constant("Title\nbody"), magnification: 1.44), width: 520, height: 360)
		defer { offscreen.close() }
		offscreen.pump()

		let scrollView = try #require(offscreen.views(of: NSScrollView.self).first { $0.allowsMagnification })
		#expect(scrollView.magnification == 1.44)
	}
}

@MainActor
struct EditorDateLineTests {
	@Test func theDateLineSitsAboveTheTitleAndScrollsWithTheNote() throws {
		let offscreen = OffscreenWindow(NoteEditor(text: .constant("Title\nbody"), dateLine: "2026.08.06 at 10:42"), width: 520, height: 360)
		defer { offscreen.close() }
		offscreen.pump()

		let textView = try #require(offscreen.views(of: NSTextView.self).first { $0.isEditable })
		let line = try #require(textView.subviews.compactMap { $0 as? NSTextField }.first)
		#expect(line.stringValue == "2026.08.06 at 10:42")
		#expect(line.frame.maxY <= NoteEditor.topInset)
		#expect(!line.isEditable && !line.isSelectable)
	}
}
