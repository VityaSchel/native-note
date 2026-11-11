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

@MainActor @Observable
private final class StatusBox {
	var status: AppModel.SyncStatus

	init(_ status: AppModel.SyncStatus) {
		self.status = status
	}
}

private struct ChangingSyncForm: View {
	let box: StatusBox

	var body: some View {
		Form { SyncSection(controls: SyncControls(status: box.status)) { _ in } }.formStyle(.grouped)
	}
}

@MainActor
struct SyncSectionTests {
	/// A retry after a failure keeps the reason's room, so Settings and an open sheet stay put while it runs.
	@Test func aRetryAfterAFailureKeepsTheSectionsHeightUntilItEnds() {
		let server = "http://127.0.0.1:8080"
		let reason = "Could not connect to the server. Check that it is running and that its address is right."
		let box = StatusBox(AppModel.SyncStatus(phase: .idle, server: server, lastSynced: .now))
		let host = NSHostingView(rootView: ChangingSyncForm(box: box).frame(width: 440))
		func height(_ phase: AppModel.SyncStatus.Phase) -> CGFloat {
			box.status.phase = phase
			for _ in 0 ..< 5 {
				host.layoutSubtreeIfNeeded()
				RunLoop.current.run(until: Date().addingTimeInterval(0.01))
			}
			return host.fittingSize.height
		}

		let idle = height(.idle)
		let syncingFresh = height(.syncing)
		let failed = height(.failed(reason))
		let retrying = height(.syncing)
		let failedAgain = height(.failed(reason))
		let synced = height(.idle)

		#expect(syncingFresh == idle)
		#expect(failed > idle)
		#expect(retrying == failed)
		#expect(failedAgain == failed)
		#expect(synced == idle)
	}

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
		try press("Change Server…", in: offscreen)
		try press("Change Recovery Phrase…", in: offscreen)
		try press("Change API Key…", in: offscreen)
		await offscreen.pump { requests.synced > 0 && requests.presented.count == 3 }
		#expect(requests.presented == [.changeServer, .changeRecoveryPhrase, .changeAPIKey])
		#expect(offscreen.accessibilityElements(.button).contains { $0.label == "Turn Off Sync…" })
	}

	@Test func theStatusLineReadsTheSyncPhase() {
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .syncing)) == "Syncing…")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .failed("Unreachable."))) == "Sync failed")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle)) == "Not synced yet")
		let synced = Date(timeIntervalSince1970: 1_800_000_000)
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle, lastSynced: synced), now: synced.addingTimeInterval(30)) == "Last synced just now")
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle, lastSynced: synced), now: synced.addingTimeInterval(300)).hasPrefix("Last synced "))
		#expect(SyncSection.statusLine(AppModel.SyncStatus(phase: .idle, lastSynced: synced), now: synced.addingTimeInterval(300)) != "Last synced just now")
	}
}
