import AppKit
import SwiftUI

@MainActor
final class OffscreenWindow<Content: View> {
	let window: SheetCatchingWindow
	let host: NSHostingView<Content>

	init(_ view: Content, width: CGFloat = 380, height: CGFloat = 620, catchesSheets: Bool = false) {
		window = SheetCatchingWindow(
			contentRect: NSRect(x: 0, y: 0, width: width, height: height),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.claimsVisible = catchesSheets
		host = NSHostingView(rootView: view)
		host.frame = NSRect(x: 0, y: 0, width: width, height: height)
		window.contentView = host
		pump(for: 0.05)
	}

	var sheet: NSWindow? {
		window.attachedSheet
	}

	func pump(for interval: TimeInterval = 0.005) {
		window.layoutIfNeeded()
		host.layoutSubtreeIfNeeded()
		host.displayIfNeeded()
		if let sheet {
			sheet.layoutIfNeeded()
			sheet.contentView?.layoutSubtreeIfNeeded()
			sheet.contentView?.displayIfNeeded()
		}
		RunLoop.current.run(until: Date().addingTimeInterval(interval))
	}

	func pump(turns: Int = 400, until done: () async throws -> Bool) async rethrows {
		for _ in 0 ..< turns {
			if try await done() { return }
			pump()
			await Task.yield()
		}
	}

	func views<View: NSView>(of type: View.Type) -> [View] {
		views(of: type, in: host)
	}

	func sheetViews<View: NSView>(of type: View.Type) -> [View] {
		sheet?.contentView.map { views(of: type, in: $0) } ?? []
	}

	private func views<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
		var found: [View] = []
		var pending: [NSView] = [root]
		while let view = pending.popLast() {
			if let match = view as? View { found.append(match) }
			pending.append(contentsOf: view.subviews)
		}
		return found
	}

	func close() {
		window.contentView = nil
		pump()
	}
}

final class SheetCatchingWindow: NSWindow {
	private var caught: [(sheet: NSWindow, ended: ((NSApplication.ModalResponse) -> Void)?)] = []
	var claimsVisible = false

	override var isVisible: Bool {
		claimsVisible || super.isVisible
	}

	override var sheets: [NSWindow] {
		caught.map(\.sheet)
	}

	override var attachedSheet: NSWindow? {
		caught.last?.sheet
	}

	override func beginSheet(_ sheet: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
		caught.append((sheet, handler))
	}

	override func beginCriticalSheet(_ sheet: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
		caught.append((sheet, handler))
	}

	override func endSheet(_ sheet: NSWindow) {
		endSheet(sheet, returnCode: .stop)
	}

	override func endSheet(_ sheet: NSWindow, returnCode: NSApplication.ModalResponse) {
		guard let index = caught.firstIndex(where: { $0.sheet === sheet }) else { return }
		caught.remove(at: index).ended?(returnCode)
	}
}
