import AppKit

@MainActor
final class FindPasteboard {
	static let shared = FindPasteboard(NSPasteboard(name: name(hostingTests: AppDelegate.hostsTests)))

	static func name(hostingTests: Bool) -> NSPasteboard.Name {
		hostingTests ? NSPasteboard.Name("dev.hloth.nativenote.tests.find") : .find
	}

	let pasteboard: NSPasteboard
	private var countWhenActivated: Int?
	private var written: Int?

	init(_ pasteboard: NSPasteboard) {
		self.pasteboard = pasteboard
	}

	func appBecameActive() {
		countWhenActivated = pasteboard.changeCount
	}

	func appResignedActive() {
		noteWhatThisAppWrote()
		countWhenActivated = nil
	}

	func clear() {
		noteWhatThisAppWrote()
		defer { written = nil }
		guard let written, pasteboard.changeCount == written else { return }
		pasteboard.clearContents()
		if countWhenActivated != nil { countWhenActivated = pasteboard.changeCount }
	}

	private func noteWhatThisAppWrote() {
		guard let countWhenActivated, pasteboard.changeCount != countWhenActivated else { return }
		written = pasteboard.changeCount
		self.countWhenActivated = written
	}
}
