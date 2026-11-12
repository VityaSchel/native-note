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

	@Test func zoomEnlargesTheTextAndLeavesTheMarginsAndDateLine() throws {
		let host = ZoomHost()
		let offscreen = OffscreenWindow(ZoomedEditor(host: host), width: 520, height: 360)
		defer { offscreen.close() }
		offscreen.pump()
		let textView = try #require(offscreen.views(of: NSTextView.self).first { $0.isEditable })
		let storage = try #require(textView.textStorage)
		func size(at location: Int) -> CGFloat {
			(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
		}
		let title = size(at: 0)
		let body = size(at: 7)
		let inset = textView.textContainerInset
		let dateLine = try #require(textView.subviews.compactMap { $0 as? NSTextField }.first)
		let dateSize = dateLine.font?.pointSize

		host.zoom = 1.44
		offscreen.pump()

		#expect(abs(size(at: 0) - title * 1.44) < 0.01)
		#expect(abs(size(at: 7) - body * 1.44) < 0.01)
		let typing = (textView.typingAttributes[.font] as? NSFont)?.pointSize ?? 0
		#expect(typing == size(at: textView.selectedRange().location <= 5 ? 0 : 7))
		#expect(textView.textContainerInset == inset)
		#expect(dateLine.font?.pointSize == dateSize)
		#expect(textView.enclosingScrollView?.magnification == 1)
	}

	@Test func textTypedAfterZoomingTakesTheZoomedSize() throws {
		let host = ZoomHost()
		host.zoom = 2
		let offscreen = OffscreenWindow(ZoomedEditor(host: host), width: 520, height: 360)
		defer { offscreen.close() }
		offscreen.pump()
		let textView = try #require(offscreen.views(of: NSTextView.self).first { $0.isEditable })
		offscreen.window.makeFirstResponder(textView)

		textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
		textView.insertText(" more", replacementRange: textView.selectedRange())
		offscreen.pump()

		let font = textView.textStorage?.attribute(.font, at: textView.string.utf16.count - 1, effectiveRange: nil) as? NSFont
		#expect(font?.pointSize == EditorStyles.bodyFont.pointSize * 2)
	}
}

@MainActor @Observable
private final class ZoomHost {
	var zoom = 1.0
	var text = "Title\nbody text"
}

private struct ZoomedEditor: View {
	@Bindable var host: ZoomHost

	var body: some View {
		NoteEditor(text: $host.text, zoom: host.zoom, dateLine: "2026.08.06 at 10:42")
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
		#expect(line.frame.maxY <= NoteEditor.dateLineInset)
		#expect(!line.isEditable && !line.isSelectable)
	}
}
