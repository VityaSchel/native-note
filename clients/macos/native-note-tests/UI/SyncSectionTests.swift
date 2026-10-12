import AppKit
import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
private final class Requests {
	var presented: [SecuritySettings.Sheet] = []
	var synced = 0
}

private struct SyncForm: View {
	let section: SyncSection

	var body: some View {
		Form { section }.formStyle(.grouped)
	}
}

@MainActor
struct SyncSectionTests {
	private func offscreen(_ status: AppModel.SyncStatus, _ requests: Requests) -> OffscreenWindow<SyncForm> {
		let controls = SyncControls(status: status, syncNow: { requests.synced += 1 })
		return OffscreenWindow(SyncForm(section: SyncSection(controls: controls) { requests.presented.append($0) }), width: 440, height: 360)
	}

	private func press(_ label: String, in offscreen: OffscreenWindow<SyncForm>) throws {
		try #require(offscreen.accessibilityElements(.button).first { $0.label == label }).press()
	}

	@Test func withoutAServerTheSectionOffersSetup() async throws {
		let requests = Requests()
		let offscreen = offscreen(AppModel.SyncStatus(), requests)
		defer { offscreen.close() }

		#expect(offscreen.accessibilityElements(.button).map(\.label) == ["Set Up Sync…"])
		try press("Set Up Sync…", in: offscreen)
		await offscreen.pump { !requests.presented.isEmpty }
		#expect(requests.presented == [.setUpSync])
	}

	@Test func withAServerTheSectionShowsItsStatusProblemsAndActions() async throws {
		let requests = Requests()
		let status = AppModel.SyncStatus(phase: .idle, server: "http://notes.example:8080/", problems: ["A note is larger than 1 MB."])
		let offscreen = offscreen(status, requests)
		defer { offscreen.close() }
		let texts = offscreen.accessibilityElements(.staticText).map(\.value)

		#expect(texts.contains("http://notes.example:8080/"))
		#expect(texts.contains("Not synced yet"))
		#expect(texts.contains("A note is larger than 1 MB."))
		try press("Sync Now", in: offscreen)
		try press("Change Recovery Phrase…", in: offscreen)
		await offscreen.pump { requests.synced > 0 && !requests.presented.isEmpty }
		#expect(requests.presented == [.changeRecoveryPhrase])
	}

	@Test func theStatusLineReadsTheSyncPhase() {
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .syncing)) == "Syncing…")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .failed("Unreachable."))) == "Unreachable.")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle)) == "Not synced yet")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle, lastSynced: Date())).hasPrefix("Last synced "))
	}
}
