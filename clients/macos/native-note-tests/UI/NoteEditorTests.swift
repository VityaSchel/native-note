import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct NoteEditorTests {
	private let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
	private let headingSize = NSFont.preferredFont(forTextStyle: .largeTitle).pointSize

	@Test func typingPushesTheTextThroughTheBindingAndStylesTheTitle() {
		let editor = Editor("")

		editor.replace(NSRange(location: 0, length: 0), with: "Shopping")

		#expect(editor.text == "Shopping")
		#expect(editor.pointSize(at: 0) == headingSize)
	}

	@Test func aChangeFromSomethingOtherThanATextViewIsIgnored() {
		let editor = Editor("untouched")

		editor.coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: nil))

		#expect(editor.text == "untouched")
	}

	@Test func returnInsideTheTitleDemotesItsTail() {
		let editor = Editor("Title")

		editor.replace(NSRange(location: 2, length: 0), with: "\n")

		#expect(editor.text == "Ti\ntle")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 3) == bodySize)
	}

	@Test func returnAtTheStartDemotesTheOldTitle() {
		let editor = Editor("Title\nbody")

		editor.replace(NSRange(location: 0, length: 0), with: "\n")

		#expect(editor.text == "\nTitle\nbody")
		#expect(editor.pointSize(at: 1) == bodySize)
	}

	@Test func deletingTheTitleLinePromotesTheNextLine() {
		let editor = Editor("Title\nbody")

		editor.replace(NSRange(location: 0, length: 6), with: "")

		#expect(editor.text == "body")
		#expect(editor.pointSize(at: 0) == headingSize)
	}

	@Test func pastingSeveralLinesAboveTheTitleDemotesIt() {
		let editor = Editor("Title\nbody")

		editor.replace(NSRange(location: 0, length: 0), with: "a\nb\n")

		#expect(editor.text == "a\nb\nTitle\nbody")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 2) == bodySize)
		#expect(editor.pointSize(at: 4) == bodySize)
	}

	@Test func typingInTheBodyKeepsTheTitle() {
		let editor = Editor("Title\nbody")

		editor.replace(NSRange(location: 6, length: 0), with: "more ")

		#expect(editor.text == "Title\nmore body")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 6) == bodySize)
	}

	@Test func loadingATextStylesTheWholeDocument() {
		let editor = Editor("Title\nbody\nmore")

		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 6) == bodySize)
		#expect(editor.pointSize(at: 11) == bodySize)
	}

	@Test func theEditorIsAPlainTextKit2ViewWithTheDesignedInset() {
		let editor = Editor("Title\nbody")
		let textView = editor.textView

		#expect(textView.textLayoutManager != nil)
		#expect(!textView.isRichText)
		#expect(textView.allowsUndo)
		#expect(textView.usesFindBar)
		#expect(textView.textContainerInset == NSSize(width: 28, height: 28))
		#expect(!textView.drawsBackground)
		#expect(!editor.scrollView.drawsBackground)
		#expect(editor.scrollView.borderType == .noBorder)
		#expect(textView.delegate === editor.coordinator)
	}

	@Test func anEchoOfTheTypedTextLeavesTheCaretAlone() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 3, length: 0))

		NoteEditor.show("Title\nbody", in: editor.scrollView)
		#expect(editor.textView.selectedRange() == NSRange(location: 3, length: 0))

		NoteEditor.show("Other\ntext", in: editor.scrollView)
		#expect(editor.textView.string == "Other\ntext")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 6) == bodySize)
	}
}

@MainActor
private final class Editor {
	var text: String
	lazy var coordinator = NoteEditor.Coordinator(
		text: Binding(get: { @MainActor [unowned self] in text }, set: { @MainActor [unowned self] in text = $0 })
	)
	lazy var scrollView = NoteEditor.makeScrollView(delegate: coordinator)
	var textView: NSTextView { scrollView.documentView as! NSTextView }

	init(_ text: String) {
		self.text = text
		NoteEditor.show(text, in: scrollView)
	}

	func replace(_ range: NSRange, with string: String) {
		textView.insertText(string, replacementRange: range)
	}

	func pointSize(at location: Int) -> CGFloat? {
		(textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
	}
}
