import AppKit

/// Copied words stay on this Mac, are marked for clipboard managers to skip, and leave the pasteboard after `keeps`,
/// unless something else was copied over them.
@MainActor
final class RecoveryClipboard {
	static let shared = RecoveryClipboard(.general)
	static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
	static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
	/// Long enough to continue, confirm and paste into a password manager, as password managers keep a copied password.
	static let keeps: Duration = .seconds(90)

	private let pasteboard: NSPasteboard
	private let sleep: @Sendable (Duration) async throws -> Void
	private var written: Int?
	private var expiry: Task<Void, Never>?

	init(_ pasteboard: NSPasteboard, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
		self.pasteboard = pasteboard
		self.sleep = sleep
	}

	func copy(_ words: [String]) {
		pasteboard.prepareForNewContents(with: .currentHostOnly)
		pasteboard.setString(words.joined(separator: " "), forType: .string)
		pasteboard.setData(Data(), forType: Self.concealed)
		pasteboard.setData(Data(), forType: Self.transient)
		written = pasteboard.changeCount
		expiry?.cancel()
		expiry = Task { [sleep] in
			guard (try? await sleep(Self.keeps)) != nil, !Task.isCancelled else { return }
			self.clear()
		}
	}

	func clear() {
		expiry?.cancel()
		expiry = nil
		defer { written = nil }
		guard let written, pasteboard.changeCount == written else { return }
		pasteboard.clearContents()
	}
}
