import AppKit
import SwiftUI

struct NoteEditor: NSViewRepresentable {
	@Binding var text: String

	func makeCoordinator() -> Coordinator {
		Coordinator(text: $text)
	}

	func makeNSView(context: Context) -> NSScrollView {
		Self.makeScrollView(delegate: context.coordinator)
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		Self.show(text, in: scrollView)
	}

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
		textView.textContainerInset = NSSize(width: 28, height: 28)
		textView.autoresizingMask = [.width]
		textView.isVerticallyResizable = true
		textView.textContainer?.widthTracksTextView = true
		textView.defaultParagraphStyle = Coordinator.bodyParagraphStyle
		textView.typingAttributes = Coordinator.bodyAttributes

		let scrollView = NSScrollView()
		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		return scrollView
	}

	static func show(_ text: String, in scrollView: NSScrollView) {
		guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
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
			text.wrappedValue = textView.string
		}

		func textDidChange(_ notification: Notification) {
			finishEdit()
		}

		@objc fileprivate func finishEdit() {
			pushText()
			guard let storage = editedStorage else { return }
			editedStorage = nil
			Self.style(storage, in: NSRange(location: 0, length: storage.length))
		}

		fileprivate static let bodyParagraphStyle: NSParagraphStyle = {
			let style = NSMutableParagraphStyle()
			style.lineHeightMultiple = 1.0
			style.paragraphSpacing = 8
			return style
		}()

		private static let bodyFont = NSFont.preferredFont(forTextStyle: .body)

		private static let bodyStyle: [NSAttributedString.Key: Any] = [
			.font: bodyFont,
			.paragraphStyle: bodyParagraphStyle,
		]

		fileprivate static let bodyAttributes = bodyStyle.merging([.foregroundColor: NSColor.textColor]) { $1 }

		private static let headingStyle: [NSAttributedString.Key: Any] = {
			let style = NSMutableParagraphStyle()
			style.lineHeightMultiple = 1.15
			style.paragraphSpacing = 14
			return [
				.font: NSFont.preferredFont(forTextStyle: .largeTitle).bold,
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
