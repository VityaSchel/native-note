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
}
