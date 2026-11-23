import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct ImportPassphraseSheetTests {
	@Test func whileTheExportIsImportedImportReadsInProgressAndTheSpinnerIsHidden() throws {
		let sheet = { (working: Bool) in ImportPassphraseSheet(refused: false, working: working, submit: { _ in }, cancel: {}) }
		let offscreen = OffscreenWindow(sheet(false), width: 400, height: 200)
		defer { offscreen.close() }
		#expect(try #require(offscreen.button("Import")).value == "")

		offscreen.host.rootView = sheet(true)
		offscreen.pump()

		let button = try #require(offscreen.button("Import"))
		#expect(!button.isEnabled)
		#expect(button.value == OnboardingLabel.busyValue)
		#expect(offscreen.views(of: NSProgressIndicator.self).count == 1)
		#expect(!offscreen.exposesASpinner)
	}
}
