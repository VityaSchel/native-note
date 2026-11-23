import AppKit
import SwiftUI
import Testing

@testable import NativeNote

private struct FailingSheet: View {
	let announcements: Spoken
	@State private var error: String?

	var body: some View {
		SheetScaffold(title: "Change Server", error: error) {
			Button("Try") { error = "The server did not accept this API key." }
		} buttons: {
			EmptyView()
		} announce: { announcements.hear($0) }
	}
}

@MainActor
struct SheetScaffoldTests {
	@Test func aNewErrorIsReadOutOnce() async throws {
		let announcements = Spoken()
		let offscreen = OffscreenWindow(FailingSheet(announcements: announcements), width: 400, height: 200)
		defer { offscreen.close() }

		try #require(offscreen.accessibilityElements(.button).first { $0.label == "Try" }).press()
		await offscreen.pump { !announcements.heard.isEmpty }

		#expect(announcements.heard == ["The server did not accept this API key."])
		#expect(announcements.lines.map(\.accessibilitySpeechAnnouncementPriority) == [.high])
	}

	@Test func errorsAreSpokenAboveTheFocusChangeThatFollowsThemAndStepLinesAfterIt() {
		#expect(VoiceOver.aboveFocusChanges("The server refused.").accessibilitySpeechAnnouncementPriority == .high)
		#expect(VoiceOver.afterFocusSpeech("Set Up Sync").accessibilitySpeechAnnouncementPriority == .low)
	}

	@Test func theWorkingSpinnerIsHiddenFromVoiceOver() {
		let offscreen = OffscreenWindow(SheetScaffold(title: "Change Server", working: true) {
			SecureField("API Key:", text: .constant(""))
		} buttons: {
			Button("Change") {}
		}, width: 400, height: 200)
		defer { offscreen.close() }

		#expect(offscreen.views(of: NSProgressIndicator.self).count == 1)
		#expect(!offscreen.exposesASpinner)
	}

	@Test func anErrorOfUpToTwoLinesMovesNothing() {
		func height(error: String?) -> CGFloat {
			NSHostingView(rootView: SheetScaffold(title: "Change Server", error: error) {
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
