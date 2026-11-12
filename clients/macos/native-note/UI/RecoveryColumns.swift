import AppKit
import SwiftUI

struct RecoveryColumns: NSViewRepresentable {
	let words: [String]

	func makeNSView(context: Context) -> RecoveryColumnsView {
		RecoveryColumnsView(words: words)
	}

	func updateNSView(_ view: RecoveryColumnsView, context: Context) {
		view.show(words)
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView: RecoveryColumnsView, context: Context) -> CGSize? {
		nsView.intrinsicContentSize
	}
}

final class RecoveryColumnsView: NSView {
	static let gap: CGFloat = 24
	private static let lineSpacing: CGFloat = 6
	fileprivate static let figureSpace = "\u{2007}"

	private let storage = NSTextStorage()
	private let typesetting = NSLayoutManager()
	private(set) var columns: [NSTextView] = []
	private var words: [String] = []
	private var anchor = 0
	private var widths: [CGFloat] = []
	private var columnHeight: CGFloat = 0

	init(words: [String]) {
		super.init(frame: .zero)
		storage.addLayoutManager(typesetting)
		for _ in 0 ..< RecoveryWords.columns {
			let container = NSTextContainer(size: .zero)
			container.lineFragmentPadding = 0
			typesetting.addTextContainer(container)
			let column = ColumnTextView(frame: .zero, textContainer: container)
			column.isEditable = false
			column.isSelectable = true
			column.drawsBackground = false
			column.textContainerInset = .zero
			column.setAccessibilityElement(false)
			addSubview(column)
			columns.append(column)
		}
		show(words)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	var text: String {
		RecoveryClipboard.list(words)
	}

	func show(_ words: [String]) {
		guard words != self.words else { return }
		self.words = words
		storage.setAttributedString(Self.attributed(words))
		place()
		setAccessibilityValue(text)
	}

	private func place() {
		let font = Self.font
		let line = typesetting.defaultLineHeight(for: font) + Self.lineSpacing
		columnHeight = line * CGFloat(RecoveryWords.rows)
		widths = columns.indices.map { index in
			ceil(Self.lines(words, column: index).map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 0) + 2
		}
		for (column, width) in zip(columns, widths) {
			column.textContainer?.size = NSSize(width: width, height: columnHeight + line / 2)
		}
		invalidateIntrinsicContentSize()
		needsLayout = true
	}

	override var intrinsicContentSize: NSSize {
		NSSize(width: widths.reduce(0, +) + Self.gap * CGFloat(max(widths.count - 1, 0)), height: columnHeight)
	}

	override func layout() {
		super.layout()
		var x = ((bounds.width - intrinsicContentSize.width) / 2).rounded(.down)
		for (column, width) in zip(columns, widths) {
			column.frame = NSRect(x: x, y: 0, width: width, height: columnHeight)
			x += width + Self.gap
		}
	}

	override var isFlipped: Bool {
		true
	}

	private static var font: NSFont {
		.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
	}

	static func lines(_ words: [String], column: Int) -> [String] {
		let numbers = (column * RecoveryWords.rows ..< min((column + 1) * RecoveryWords.rows, words.count)).map { $0 + 1 }
		let width = String(numbers.last ?? 0).count
		return numbers.map { String(repeating: figureSpace, count: width - String($0).count) + "\($0). \(words[$0 - 1])" }
	}

	private static func attributed(_ words: [String]) -> NSAttributedString {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineSpacing = lineSpacing
		let text = NSMutableAttributedString()
		let lines = (0 ..< RecoveryWords.columns).flatMap { Self.lines(words, column: $0) }
		for (index, line) in lines.enumerated() {
			let split = line.firstIndex(of: " ").map { line.index(after: $0) } ?? line.startIndex
			text.append(NSAttributedString(string: String(line[..<split]), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
			text.append(NSAttributedString(string: String(line[split...]) + (index < lines.count - 1 ? "\n" : ""), attributes: [.foregroundColor: NSColor.labelColor]))
		}
		text.addAttributes([.font: font, .paragraphStyle: paragraph], range: NSRange(location: 0, length: text.length))
		return text
	}

	override func hitTest(_ point: NSPoint) -> NSView? {
		frame.contains(point) ? self : nil
	}

	override func resetCursorRects() {
		addCursorRect(bounds, cursor: .iBeam)
	}

	override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
		true
	}

	var selectedRange: NSRange {
		columns.first?.selectedRange() ?? NSRange(location: 0, length: 0)
	}

	func characterIndex(at point: NSPoint) -> Int {
		let column = columns.min { distance(point, $0.frame) < distance(point, $1.frame) } ?? columns[0]
		let local = column.convert(point, from: self)
		let clamped = NSPoint(x: min(max(local.x, 0), column.bounds.width), y: min(max(local.y, 0), column.bounds.height - 1))
		return column.characterIndexForInsertion(at: clamped)
	}

	private func distance(_ point: NSPoint, _ rect: NSRect) -> CGFloat {
		point.x < rect.minX ? rect.minX - point.x : point.x > rect.maxX ? point.x - rect.maxX : 0
	}

	override func mouseDown(with event: NSEvent) {
		guard let first = columns.first else { return }
		window?.makeFirstResponder(first)
		let index = characterIndex(at: convert(event.locationInWindow, from: nil))
		anchor = index
		let granularity: NSSelectionGranularity? = switch event.clickCount {
		case 2: .selectByWord
		case 3...: .selectByParagraph
		default: nil
		}
		if let granularity {
			first.setSelectedRange(first.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: granularity))
		} else {
			first.setSelectedRange(NSRange(location: index, length: 0))
		}
	}

	override func mouseDragged(with event: NSEvent) {
		let index = characterIndex(at: convert(event.locationInWindow, from: nil))
		columns.first?.setSelectedRange(NSRange(location: min(anchor, index), length: abs(index - anchor)))
	}

	override func menu(for event: NSEvent) -> NSMenu? {
		let menu = NSMenu()
		menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "").target = columns.first
		return menu
	}

	override func isAccessibilityElement() -> Bool {
		true
	}

	override func accessibilityRole() -> NSAccessibility.Role? {
		.staticText
	}

	override func accessibilityChildren() -> [Any]? {
		[]
	}
}

private final class ColumnTextView: NSTextView {
	override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
		let text = (string as NSString).substring(with: selectedRange()).replacingOccurrences(of: RecoveryColumnsView.figureSpace, with: "")
		guard !text.isEmpty else { return false }
		pasteboard.clearContents()
		return pasteboard.setString(text, forType: .string)
	}

	override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
		[.string]
	}
}
