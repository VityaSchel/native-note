import AppKit
import SwiftUI

struct NoteEditor: NSViewRepresentable {
	@Binding var text: String
	/// New Note puts the insertion point in the note it made; picking a note in the list leaves focus there.
	var takesFocus = false
	var tookFocus: () -> Void = {}
	var magnification = 1.0
	var dateLine = ""

	func makeCoordinator() -> Coordinator {
		Coordinator(text: $text)
	}

	func makeNSView(context: Context) -> NSScrollView {
		Self.makeScrollView(delegate: context.coordinator)
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		Self.show(text, in: scrollView)
		if context.coordinator.dateLabel?.stringValue != dateLine {
			context.coordinator.dateLabel?.stringValue = dateLine
		}
		if abs(scrollView.magnification - magnification) > 0.001 {
			scrollView.magnification = magnification
		}
		guard takesFocus, let textView = scrollView.documentView as? NSTextView else { return }
		DispatchQueue.main.async { [tookFocus] in
			guard let window = textView.window else { return }
			window.makeFirstResponder(textView)
			tookFocus()
		}
	}

	/// Room above the title for the date line, which scrolls with the note as in Notes.
	static let topInset: CGFloat = 46

	static func makeScrollView(delegate: Coordinator) -> NSScrollView {
		let textView = ComposingTextView(usingTextLayoutManager: true)
		textView.delegate = delegate
		textView.textStorage?.delegate = delegate
		delegate.textView = textView
		textView.isEditable = true
		textView.isSelectable = true
		textView.isRichText = false
		textView.allowsUndo = true
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.drawsBackground = false
		textView.textContainerInset = NSSize(width: 28, height: Self.topInset)

		let dateLabel = NSTextField(labelWithString: "")
		dateLabel.font = .preferredFont(forTextStyle: .subheadline)
		dateLabel.textColor = .secondaryLabelColor
		dateLabel.alignment = .center
		dateLabel.translatesAutoresizingMaskIntoConstraints = false
		textView.addSubview(dateLabel)
		NSLayoutConstraint.activate([
			dateLabel.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
			dateLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 16),
		])
		delegate.dateLabel = dateLabel
		textView.autoresizingMask = [.width]
		textView.isVerticallyResizable = true
		textView.textContainer?.widthTracksTextView = true
		textView.defaultParagraphStyle = Coordinator.bodyParagraphStyle
		textView.typingAttributes = Coordinator.headingAttributes

		let scrollView = NSScrollView()
		scrollView.allowsMagnification = true
		scrollView.minMagnification = EditorZoom.range.lowerBound
		scrollView.maxMagnification = EditorZoom.range.upperBound
		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		return scrollView
	}

	/// The model echoing what the editor last showed or pushed leaves the view alone, so a composition in progress survives it.
	static func show(_ text: String, in scrollView: NSScrollView) {
		guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
		let coordinator = textView.delegate as? Coordinator
		guard text != coordinator?.shown else { return }
		coordinator?.shown = text
		guard textView.string != text else { return }
		let delegate = storage.delegate
		storage.delegate = nil
		textView.string = text
		let whole = NSRange(location: 0, length: storage.length)
		storage.setAttributes(Coordinator.bodyAttributes, range: whole)
		Coordinator.style(storage, in: whole)
		storage.delegate = delegate
		textView.undoManager?.removeAllActions()
	}

	@MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
		private let text: Binding<String>
		private let history = UndoManager()
		fileprivate weak var textView: NSTextView?
		fileprivate weak var dateLabel: NSTextField?
		fileprivate var shown: String?
		private weak var editedStorage: NSTextStorage?
		private var unpushed = false

		init(text: Binding<String>) {
			self.text = text
			super.init()
			for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
				NotificationCenter.default.addObserver(self, selector: #selector(finishEdit), name: name, object: history)
			}
		}

		func undoManager(for view: NSTextView) -> UndoManager? {
			history
		}

		func textStorage(
			_ textStorage: NSTextStorage,
			willProcessEditing editedMask: NSTextStorageEditActions,
			range editedRange: NSRange,
			changeInLength delta: Int
		) {
			Self.style(textStorage, in: editedRange)
			guard editedMask.contains(.editedCharacters) else { return }
			editedStorage = textStorage
			unpushed = true
			pushText()
		}

		private func pushText() {
			guard unpushed, let textView, !textView.hasMarkedText() else { return }
			unpushed = false
			shown = textView.string
			text.wrappedValue = textView.string
		}

		func textDidChange(_ notification: Notification) {
			finishEdit()
		}

		func textViewDidChangeSelection(_ notification: Notification) {
			guard let textView, !textView.hasMarkedText() else { return }
			let text = textView.string as NSString
			let newline = text.rangeOfCharacter(from: .newlines)
			let titleEnd = newline.location == NSNotFound ? text.length : newline.location
			let typing = textView.selectedRange().location <= titleEnd ? Self.headingAttributes : Self.bodyAttributes
			guard textView.typingAttributes[.font] as? NSFont != typing[.font] as? NSFont else { return }
			textView.typingAttributes = typing
		}

		@objc fileprivate func finishEdit() {
			pushText()
			guard let storage = editedStorage else { return }
			editedStorage = nil
			Self.style(storage, in: NSRange(location: 0, length: storage.length))
		}

		fileprivate static let bodyParagraphStyle: NSParagraphStyle = {
			let style = NSMutableParagraphStyle()
			style.lineSpacing = 3
			style.paragraphSpacing = 2
			return style
		}()

		private static let bodyFont = NSFont.preferredFont(forTextStyle: .body).withSingleStoreyA

		private static let bodyStyle: [NSAttributedString.Key: Any] = [
			.font: bodyFont,
			.paragraphStyle: bodyParagraphStyle,
		]

		fileprivate static let bodyAttributes = bodyStyle.merging([.foregroundColor: NSColor.textColor]) { $1 }

		fileprivate static let headingAttributes = headingStyle.merging([.foregroundColor: NSColor.textColor]) { $1 }

		private static let headingStyle: [NSAttributedString.Key: Any] = {
			let style = NSMutableParagraphStyle()
			style.lineHeightMultiple = 1.15
			style.paragraphSpacing = 8
			return [
				.font: NSFont.preferredFont(forTextStyle: .largeTitle).bold.withSingleStoreyA,
				.paragraphStyle: style,
			]
		}()

		fileprivate static func style(_ storage: NSTextStorage, in range: NSRange) {
			let heading = storage.mutableString.lineRange(for: NSRange(location: 0, length: 0))
			let body = NSRange(location: heading.upperBound, length: storage.length - heading.upperBound)
			storage.beginEditing()
			apply(headingStyle, to: NSIntersectionRange(range, heading), in: storage)
			apply(bodyStyle, to: NSIntersectionRange(range, body), in: storage)
			storage.endEditing()
		}

		private static func apply(_ style: [NSAttributedString.Key: Any], to range: NSRange, in storage: NSTextStorage) {
			guard range.length > 0 else { return }
			let font = style[.font] as? NSFont
			storage.enumerateAttribute(.font, in: range) { value, run, _ in
				guard value as? NSFont != font else { return }
				storage.addAttributes(style, range: run)
			}
		}
	}
}

private final class ComposingTextView: NSTextView {
	override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
		(delegate as? NoteEditor.Coordinator)?.finishEdit()
	}
}

private extension NSFont {
	var bold: NSFont {
		let descriptor = fontDescriptor.withSymbolicTraits(.bold)
		return NSFont(descriptor: descriptor, size: pointSize) ?? self
	}
}

#Preview("Editor") {
	@Previewable @State var text =
		"Shopping\n\nquartz, bread, and a new kettle.\nThe first line is the title and renders as a heading."

	NoteEditor(text: $text)
		.frame(width: 520, height: 360)
}

#Preview("Editor, empty") {
	NoteEditor(text: .constant(""))
		.frame(width: 520, height: 360)
}
