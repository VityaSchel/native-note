import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
private final class Announcements {
	var heard: [String] = []
}

private struct FailingSheet: View {
	let announcements: Announcements
	@State private var error: String?

	var body: some View {
		SheetScaffold(title: "Change API Key", error: error) {
			Button("Try") { error = "The server did not accept this API key." }
		} buttons: {
			EmptyView()
		} announce: { announcements.heard.append($0) }
	}
}

@MainActor
struct SheetScaffoldTests {
	@Test func aNewErrorIsReadOutOnce() async throws {
		let announcements = Announcements()
		let offscreen = OffscreenWindow(FailingSheet(announcements: announcements), width: 400, height: 200)
		defer { offscreen.close() }

		try #require(offscreen.accessibilityElements(.button).first { $0.label == "Try" }).press()
		await offscreen.pump { !announcements.heard.isEmpty }

		#expect(announcements.heard == ["The server did not accept this API key."])
	}

	@Test func anErrorOfUpToTwoLinesMovesNothing() {
		func height(error: String?) -> CGFloat {
			NSHostingView(rootView: SheetScaffold(title: "Change API Key", error: error) {
				SecureField("API Key:", text: .constant(""))
			} buttons: {
				Button("Change") {}
			}).fittingSize.height
		}

		let empty = height(error: nil)

		#expect(height(error: "The server did not accept this API key.") == empty)
		#expect(height(error: "The server could not be reached. Check the address, and that the server is running and reachable from this Mac.") == empty)
		#expect(height(error: String(repeating: "The server could not be reached. ", count: 8)) > empty)
	}
}
