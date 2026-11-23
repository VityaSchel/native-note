import AppKit
import SwiftUI

struct NoteEditor: NSViewRepresentable {
	@Binding var text: String
	var takesFocus = false
	var tookFocus: () -> Void = {}
	var zoom = 1.0
	var dateLine = ""
	var spokenDateLine = ""

	func makeCoordinator() -> Coordinator {
		Coordinator(text: $text)
	}

	func makeNSView(context: Context) -> NSScrollView {
		Self.makeScrollView(delegate: context.coordinator)
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		Self.show(text, in: scrollView)
		context.coordinator.dateLabel?.show(dateLine, spoken: spokenDateLine)
		context.coordinator.zoom(to: zoom)
		guard takesFocus, let textView = scrollView.documentView as? NSTextView else { return }
		Self.focus(textView, then: tookFocus)
	}

	static func focus(_ textView: NSTextView, waitingForAWindow attempts: Int = 20, then tookFocus: @escaping () -> Void) {
		DispatchQueue.main.asyncAfter(deadline: .now() + (attempts < 20 ? 0.05 : 0)) {
			guard let window = textView.window else {
				if attempts > 0 { focus(textView, waitingForAWindow: attempts - 1, then: tookFocus) }
				return
			}
			window.makeFirstResponder(textView)
			tookFocus()
		}
	}

	static let dateLineInset: CGFloat = 46
	static let spokenName = "Note"

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
		textView.textContainerInset = NSSize(width: 28, height: Self.dateLineInset)
		textView.setAccessibilityLabel(Self.spokenName)

		let dateLabel = DateLineField(labelWithString: "")
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
		textView.defaultParagraphStyle = delegate.styles.bodyParagraph
		textView.typingAttributes = delegate.styles.headingTyping

		let scrollView = EditorScrollView()
		scrollView.dateLabel = dateLabel
		scrollView.documentView = textView
		scrollView.hasVerticalScroller = true
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		return scrollView
	}

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
		let styles = coordinator?.styles ?? EditorStyles(zoom: 1)
		storage.setAttributes(styles.bodyTyping, range: whole)
		Coordinator.style(storage, in: whole, with: styles)
		storage.delegate = delegate
		textView.undoManager?.removeAllActions()
	}

	@MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
		private let text: Binding<String>
		private let history = UndoManager()
		fileprivate weak var textView: NSTextView?
		fileprivate weak var dateLabel: DateLineField?
		fileprivate var shown: String?
		fileprivate private(set) var styles = EditorStyles(zoom: 1)
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

		fileprivate func zoom(to zoom: Double) {
			guard abs(styles.zoom - zoom) > 0.001 else { return }
			styles = EditorStyles(zoom: zoom)
			guard let textView, let storage = textView.textStorage else { return }
			Self.style(storage, in: NSRange(location: 0, length: storage.length), with: styles)
			textView.defaultParagraphStyle = styles.bodyParagraph
			textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification))
		}

		func textStorage(
			_ textStorage: NSTextStorage,
			willProcessEditing editedMask: NSTextStorageEditActions,
			range editedRange: NSRange,
			changeInLength delta: Int
		) {
			Self.style(textStorage, in: editedRange, with: styles)
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
			let typing = textView.selectedRange().location <= titleEnd ? styles.headingTyping : styles.bodyTyping
			guard textView.typingAttributes[.font] as? NSFont != typing[.font] as? NSFont else { return }
			textView.typingAttributes = typing
		}

		@objc fileprivate func finishEdit() {
			pushText()
			guard let storage = editedStorage else { return }
			editedStorage = nil
			Self.style(storage, in: NSRange(location: 0, length: storage.length), with: styles)
		}

		fileprivate static func style(_ storage: NSTextStorage, in range: NSRange, with styles: EditorStyles) {
			let heading = storage.mutableString.lineRange(for: NSRange(location: 0, length: 0))
			let body = NSRange(location: heading.upperBound, length: storage.length - heading.upperBound)
			storage.beginEditing()
			apply(styles.heading, to: NSIntersectionRange(range, heading), in: storage)
			apply(styles.body, to: NSIntersectionRange(range, body), in: storage)
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

struct EditorStyles {
	let zoom: Double
	let heading: [NSAttributedString.Key: Any]
	let body: [NSAttributedString.Key: Any]
	let bodyParagraph: NSParagraphStyle

	var headingTyping: [NSAttributedString.Key: Any] { heading.merging([.foregroundColor: NSColor.textColor]) { $1 } }
	var bodyTyping: [NSAttributedString.Key: Any] { body.merging([.foregroundColor: NSColor.textColor]) { $1 } }

	init(zoom: Double) {
		self.zoom = zoom
		let bodyParagraph = NSMutableParagraphStyle()
		bodyParagraph.lineSpacing = 3 * zoom
		bodyParagraph.paragraphSpacing = 2 * zoom
		self.bodyParagraph = bodyParagraph
		body = [.font: Self.bodyFont.scaled(by: zoom), .paragraphStyle: bodyParagraph]
		let headingParagraph = NSMutableParagraphStyle()
		headingParagraph.lineHeightMultiple = 1.15
		headingParagraph.paragraphSpacing = 8 * zoom
		heading = [.font: Self.headingFont.scaled(by: zoom), .paragraphStyle: headingParagraph]
	}

	static let bodyFont = NSFont.preferredFont(forTextStyle: .body).withSingleStoreyA
	static let headingFont = NSFont.preferredFont(forTextStyle: .largeTitle).bold.withSingleStoreyA
}

private final class ComposingTextView: NSTextView {
	override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
		super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
		(delegate as? NoteEditor.Coordinator)?.finishEdit()
	}
}

private final class DateLineField: NSTextField {
	private(set) var spoken = ""

	func show(_ line: String, spoken: String) {
		if stringValue != line { stringValue = line }
		self.spoken = spoken
	}

	override func isAccessibilityElement() -> Bool {
		true
	}

	override func accessibilityRole() -> NSAccessibility.Role? {
		.staticText
	}

	override func accessibilityValue() -> String? {
		spoken
	}

	override func accessibilityChildren() -> [Any]? {
		[]
	}

	override func accessibilityParent() -> Any? {
		enclosingScrollView ?? super.accessibilityParent()
	}
}

private final class EditorScrollView: NSScrollView {
	weak var dateLabel: DateLineField?

	override func accessibilityChildren() -> [Any]? {
		let children = super.accessibilityChildren() ?? []
		guard let dateLabel, !dateLabel.spoken.isEmpty else { return children }
		return [dateLabel] + children
	}
}

private extension NSFont {
	func scaled(by zoom: Double) -> NSFont {
		NSFont(descriptor: fontDescriptor, size: pointSize * zoom) ?? self
	}

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
