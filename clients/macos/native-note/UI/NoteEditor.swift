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
		let textView = NSTextView(usingTextLayoutManager: true)
		textView.delegate = delegate
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
		guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
		textView.string = text
		Coordinator.style(textView, .wholeDocument)
	}

	@MainActor final class Coordinator: NSObject, NSTextViewDelegate {
		private let text: Binding<String>

		init(text: Binding<String>) {
			self.text = text
		}

		func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			Self.style(textView, .headingNeighborhood)
			text.wrappedValue = textView.string
		}

		fileprivate static let bodyParagraphStyle: NSParagraphStyle = {
			let style = NSMutableParagraphStyle()
			style.lineHeightMultiple = 1.0
			style.paragraphSpacing = 8
			return style
		}()

		private static let bodyFont = NSFont.preferredFont(forTextStyle: .body)

		fileprivate static let bodyAttributes: [NSAttributedString.Key: Any] = [
			.font: bodyFont,
			.foregroundColor: NSColor.textColor,
			.paragraphStyle: bodyParagraphStyle,
		]

		private static let headingAttributes: [NSAttributedString.Key: Any] = {
			let style = NSMutableParagraphStyle()
			style.lineHeightMultiple = 1.15
			style.paragraphSpacing = 14
			return [
				.font: NSFont.preferredFont(forTextStyle: .largeTitle).bold,
				.foregroundColor: NSColor.textColor,
				.paragraphStyle: style,
			]
		}()

		fileprivate enum Scope {
			case wholeDocument
			case headingNeighborhood
		}

		fileprivate static func style(_ textView: NSTextView, _ scope: Scope) {
			guard let storage = textView.textStorage else { return }
			let string = storage.string as NSString
			let heading = string.lineRange(for: NSRange(location: 0, length: 0))
			let rest = NSRange(location: heading.upperBound, length: string.length - heading.upperBound)

			storage.beginEditing()
			switch scope {
			case .wholeDocument:
				storage.setAttributes(bodyAttributes, range: rest)
			case .headingNeighborhood:
				storage.enumerateAttribute(.font, in: rest) { font, range, _ in
					guard font as? NSFont != bodyFont else { return }
					storage.setAttributes(bodyAttributes, range: range)
				}
			}
			storage.setAttributes(headingAttributes, range: heading)
			storage.endEditing()
		}
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
