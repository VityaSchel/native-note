import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

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

	@Test func aChangeToAttributesAloneIsIgnored() {
		let editor = Editor("Title\nbody")
		let body = NSRange(location: 6, length: 4)

		editor.textView.textStorage?.addAttribute(.foregroundColor, value: NSColor.red, range: body)

		#expect(editor.writes.isEmpty)
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
		#expect(textView.textStorage?.delegate === editor.coordinator)
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

	@Test func undoingAPasteAboveTheTitleRestoresItsHeading() {
		let editor = Editor("Title\nbody")
		editor.replace(NSRange(location: 0, length: 0), with: "a\nb\n")

		editor.undoManager.undo()

		#expect(editor.textView.string == "Title\nbody")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 6) == bodySize)
		#expect(editor.text == editor.textView.string)
		#expect(editor.renderedParagraphHeights() == Editor("Title\nbody").renderedParagraphHeights())
	}

	@Test func theBindingFollowsTypingUndoAndRedo() {
		let editor = Editor("Title\nbody")

		editor.replace(NSRange(location: 10, length: 0), with: " more")
		#expect(editor.text == "Title\nbody more")

		editor.undoManager.undo()
		#expect(editor.textView.string == "Title\nbody")
		#expect(editor.text == editor.textView.string)

		editor.undoManager.redo()
		#expect(editor.textView.string == "Title\nbody more")
		#expect(editor.text == editor.textView.string)
		#expect(editor.writes == ["Title\nbody more", "Title\nbody", "Title\nbody more"])
		#expect(editor.undoManager.canUndo)
	}

	@Test func undoAndRedoOfAReturnInsideTheTitleRestyleBothHalves() {
		let editor = Editor("Title\nbody")
		editor.replace(NSRange(location: 2, length: 0), with: "\n")

		editor.undoManager.undo()
		#expect(editor.text == "Title\nbody")
		#expect((0 ..< 5).allSatisfy { editor.pointSize(at: $0) == headingSize })

		editor.undoManager.redo()
		#expect(editor.text == "Ti\ntle\nbody")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 3) == bodySize)
	}

	@Test func undoingATitleDeletionDemotesTheLineItPromoted() {
		let editor = Editor("Title\nbody")
		editor.replace(NSRange(location: 0, length: 6), with: "")

		editor.undoManager.undo()

		#expect(editor.text == "Title\nbody")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 6) == bodySize)
	}

	@Test func showingATextNeverWritesItBackToTheBinding() {
		let editor = Editor("Title\nbody")

		NoteEditor.show("Other\ntext", in: editor.scrollView)

		#expect(editor.textView.string == "Other\ntext")
		#expect(editor.text == "Title\nbody")
		#expect(editor.writes.isEmpty)
	}

	@Test func composingInsideTheTitleReachesTheBindingOnlyWhenCommitted() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 2, length: 0))

		editor.compose("に")
		editor.compose("にほ")
		#expect(editor.textView.hasMarkedText())
		#expect(editor.textView.markedRange() == NSRange(location: 2, length: 2))
		#expect(editor.writes.isEmpty)

		editor.type("日本")
		#expect(!editor.textView.hasMarkedText())
		#expect(editor.writes == ["Ti日本tle\nbody"])
		#expect((0 ..< 7).allSatisfy { editor.pointSize(at: $0) == headingSize })
	}

	@Test func aCompositionInAnEmptyNoteCommitsAsTheTitle() {
		let editor = Editor("")

		editor.compose("にほ")
		#expect(editor.textView.hasMarkedText())
		#expect(editor.textView.markedRange() == NSRange(location: 0, length: 2))
		#expect(editor.text == "")

		editor.type("日本")
		#expect(!editor.textView.hasMarkedText())
		#expect(editor.text == "日本")
		#expect(editor.pointSize(at: 0) == headingSize)
	}

	@Test func acceptingACompositionAsTypedKeepsItInTheBinding() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
		editor.compose("にほ")

		editor.acceptComposition()

		#expect(!editor.textView.hasMarkedText())
		#expect(editor.textView.string == "Title\nbodyにほ")
		#expect(editor.text == editor.textView.string)
	}

	@Test func cancellingACompositionTakesItOutOfTheBinding() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 10, length: 0))
		editor.compose("にほ")

		editor.compose("")

		#expect(!editor.textView.hasMarkedText())
		#expect(editor.textView.string == "Title\nbody")
		#expect(editor.text == editor.textView.string)
	}

	@Test(arguments: [
		("Title\nbody", NSRange(location: 0, length: 5)),
		("Title\nbody", NSRange(location: 2, length: 0)),
		("", NSRange(location: 0, length: 0)),
	])
	func aCompositionInTheTitleIsStyledAsTheTitleBeforeItIsCommitted(text: String, selection: NSRange) {
		let editor = Editor(text)
		editor.textView.setSelectedRange(selection)

		editor.compose("に")

		#expect(editor.textView.markedRange() == NSRange(location: selection.location, length: 1))
		#expect(editor.pointSize(at: selection.location) == headingSize)
	}

	@Test(arguments: [(2, "Tiheytle\nbody"), (5, "Titlehey\nbody")])
	func typingInTheTitleLeavesTheCaretAfterEachTypedCharacter(caret: Int, typed: String) {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: caret, length: 0))

		for character in "hey" {
			editor.type(String(character))
		}

		#expect(editor.text == typed)
		#expect(editor.textView.selectedRange() == NSRange(location: caret + 3, length: 0))
		#expect((0 ..< 8).allSatisfy { editor.pointSize(at: $0) == headingSize })
		#expect(editor.pointSize(at: 9) == bodySize)
	}

	@Test func backspaceInTheTitleDeletesOnlyTheCharactersBeforeTheCaret() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 3, length: 0))

		editor.deleteBackward()
		editor.deleteBackward()

		#expect(editor.text == "Tle\nbody")
		#expect(editor.textView.selectedRange() == NSRange(location: 1, length: 0))
	}

	@Test func returnInsideTheTitleMovesTheCaretToTheStartOfTheNewLine() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 2, length: 0))

		editor.type("\n")
		#expect(editor.textView.selectedRange() == NSRange(location: 3, length: 0))

		editor.type("z")
		#expect(editor.text == "Ti\nztle\nbody")
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(editor.pointSize(at: 3) == bodySize)
	}

	@Test func typingAfterACompositionCommittedInTheTitleContinuesAfterIt() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
		editor.compose("にほ")
		editor.type("日本")
		#expect(editor.textView.selectedRange() == NSRange(location: 4, length: 0))

		editor.type("x")

		#expect(editor.text == "Ti日本xtle\nbody")
	}

	@Test func undoingTypingInTheTitlePutsTheCaretWhereTheTypingStarted() {
		let editor = Editor("Title\nbody")
		editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
		editor.type("XY")

		editor.undoManager.undo()

		#expect(editor.text == "Title\nbody")
		#expect(editor.textView.selectedRange() == NSRange(location: 2, length: 0))
	}

	@Test func aKeystrokeMarksOnlyTheTypedCharacterAsEdited() {
		let editor = Editor("Title\n" + String(repeating: "A line of the body.\n", count: 200))

		editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
		#expect(editor.editedRanges { editor.type("a") } == [NSRange(location: 5, length: 1)])

		let end = (editor.textView.string as NSString).length
		editor.textView.setSelectedRange(NSRange(location: end, length: 0))
		#expect(editor.editedRanges { editor.type("a") } == [NSRange(location: end, length: 1)])
	}

	@Test func showingAnotherTextForgetsTheUndoHistoryOfTheOldOne() {
		let editor = Editor("Title\nbody")
		editor.replace(NSRange(location: 10, length: 0), with: " more")

		NoteEditor.show("Other\ntext that is longer", in: editor.scrollView)
		#expect(!editor.undoManager.canUndo)

		editor.undoManager.undo()
		#expect(editor.textView.string == "Other\ntext that is longer")
		#expect(editor.writes == ["Title\nbody more"])
	}

	@Test(arguments: [
		("Title\nbody", NSRange(location: 0, length: 6)),
		("Title\nbody\nmore", NSRange(location: 0, length: 6)),
		("Title\nbody\nmore", NSRange(location: 3, length: 5)),
	])
	func aCompositionOverTheEndOfTheTitleStylesTheNewTitleLineUntilItIsCancelled(text: String, selection: NSRange) {
		let editor = Editor(text)
		editor.textView.setSelectedRange(selection)

		editor.compose("に")
		#expect(editor.textView.hasMarkedText())
		#expect(onlyTheTitleLineIsAHeading(in: editor))

		editor.compose("")
		#expect(!editor.textView.hasMarkedText())
		#expect(editor.pointSize(at: 0) == headingSize)
		#expect(onlyTheTitleLineIsAHeading(in: editor))
		#expect(editor.text == editor.textView.string)
	}

	@Test func undoInTheShownNoteReachesTheNote() throws {
		let note = Note.sample(1, "First\nnote", minutesAgo: 5)
		let model = AppModel.previewing([note])
		let library = Library(model)
		defer { library.close() }
		let editor = try #require(library.editor(showing: note.body))
		#expect(library.focus(editor))

		editor.insertText("x", replacementRange: NSRange(location: (note.body as NSString).length, length: 0))
		library.settle()
		#expect(model.notes.first?.body == "First\nnotex")

		#expect(library.perform("undo:"))
		#expect(model.notes.first?.body == "First\nnote")

		#expect(library.perform("redo:"))
		#expect(model.notes.first?.body == "First\nnotex")
	}

	@Test func undoAfterSwitchingToAnotherNoteLeavesTheNoteThatWasLeftAlone() throws {
		let first = Note.sample(1, "First\nnote", minutesAgo: 5)
		let second = Note.sample(2, "Second\nnote", minutesAgo: 10)
		let model = AppModel.previewing([first, second])
		let library = Library(model)
		defer { library.close() }
		let firstEditor = try #require(library.editor(showing: first.body))
		#expect(library.focus(firstEditor))
		firstEditor.insertText("x", replacementRange: NSRange(location: (first.body as NSString).length, length: 0))
		library.settle()
		let typed = model.notes.first { $0.id == first.id }
		#expect(typed?.body == "First\nnotex")

		model.selection = second.id
		library.settle()
		let secondEditor = try #require(library.editor(showing: second.body))

		#expect(library.perform("undo:"))
		#expect(library.focus(secondEditor))
		#expect(library.perform("undo:"))

		#expect(model.notes.first { $0.id == first.id } == typed)
		#expect(model.notes.first { $0.id == second.id } == second)
		#expect(secondEditor.string == second.body)
	}

	private func onlyTheTitleLineIsAHeading(in editor: Editor) -> Bool {
		let string = editor.textView.string as NSString
		let title = string.lineRange(for: NSRange(location: 0, length: 0))
		return (0 ..< string.length).allSatisfy { editor.pointSize(at: $0) == (title.contains($0) ? headingSize : bodySize) }
	}
}

@MainActor
private final class Editor {
	var text: String
	private(set) var writes: [String] = []
	lazy var coordinator = NoteEditor.Coordinator(
		text: Binding(
			get: { @MainActor [unowned self] in text },
			set: { @MainActor [unowned self] in
				writes.append($0)
				text = $0
			}
		)
	)
	lazy var scrollView = NoteEditor.makeScrollView(delegate: coordinator)
	var textView: NSTextView { scrollView.documentView as! NSTextView }
	var undoManager: UndoManager { textView.undoManager! }

	init(_ text: String) {
		self.text = text
		scrollView.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
		textView.frame = scrollView.bounds
		NoteEditor.show(text, in: scrollView)
	}

	func replace(_ range: NSRange, with string: String) {
		undoable { textView.insertText(string, replacementRange: range) }
	}

	func compose(_ marked: String) {
		let caret = NSRange(location: (marked as NSString).length, length: 0)
		undoable { textView.setMarkedText(marked, selectedRange: caret, replacementRange: NSRange(location: NSNotFound, length: 0)) }
	}

	func type(_ string: String) {
		undoable { textView.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
	}

	func deleteBackward() {
		undoable { textView.deleteBackward(nil) }
	}

	func acceptComposition() {
		undoable { textView.unmarkText() }
	}

	func editedRanges(during change: () -> Void) -> [NSRange] {
		let recorder = EditRecorder(textView.textStorage)
		change()
		return recorder.ranges
	}

	func pointSize(at location: Int) -> CGFloat? {
		(textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
	}

	func renderedParagraphHeights() -> [CGFloat] {
		guard let layout = textView.textLayoutManager else { return [] }
		var heights: [CGFloat] = []
		layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
			heights.append(fragment.layoutFragmentFrame.height)
			return true
		}
		return heights
	}

	private func undoable(_ change: () -> Void) {
		undoManager.beginUndoGrouping()
		change()
		undoManager.endUndoGrouping()
		textView.breakUndoCoalescing()
	}
}

private final class EditRecorder: NSObject {
	private(set) var ranges: [NSRange] = []

	init(_ storage: NSTextStorage?) {
		super.init()
		NotificationCenter.default.addObserver(self, selector: #selector(record), name: NSTextStorage.didProcessEditingNotification, object: storage)
	}

	@objc private func record(_ notification: Notification) {
		guard let storage = notification.object as? NSTextStorage else { return }
		ranges.append(storage.editedRange)
	}
}

@MainActor
private final class Library {
	private let offscreen: OffscreenWindow<ContentView>

	init(_ model: AppModel) {
		offscreen = OffscreenWindow(ContentView(model: model), width: 980, height: 560)
		settle()
	}

	func settle() {
		for _ in 0 ..< 3 {
			offscreen.pump(for: 0.05)
		}
	}

	func editor(showing text: String) -> NSTextView? {
		offscreen.views(of: NSTextView.self).first { $0.string == text }
	}

	func focus(_ responder: NSResponder) -> Bool {
		offscreen.window.makeFirstResponder(responder)
	}

	func perform(_ action: String) -> Bool {
		defer { settle() }
		return offscreen.window.firstResponder?.tryToPerform(NSSelectorFromString(action), with: nil) ?? false
	}

	func close() {
		offscreen.close()
	}
}
