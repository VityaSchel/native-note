import AppKit

/// Copied words stay on this Mac, marked for clipboard histories to skip, until setup is cancelled, the library locks or the app quits.
@MainActor
final class RecoveryClipboard {
	static let shared = RecoveryClipboard(.general)
	static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
	static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

	private let pasteboard: NSPasteboard
	private var written: Int?

	init(_ pasteboard: NSPasteboard) {
		self.pasteboard = pasteboard
	}

	static func list(_ words: [String]) -> String {
		words.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
	}

	func copy(_ words: [String]) {
		pasteboard.prepareForNewContents(with: .currentHostOnly)
		pasteboard.setString(Self.list(words), forType: .string)
		pasteboard.setData(Data(), forType: Self.concealed)
		pasteboard.setData(Data(), forType: Self.transient)
		written = pasteboard.changeCount
	}

	func clear() {
		defer { written = nil }
		guard let written, pasteboard.changeCount == written else { return }
		pasteboard.clearContents()
	}
}
