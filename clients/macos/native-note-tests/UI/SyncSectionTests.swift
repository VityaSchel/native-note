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

@MainActor
private final class SyncRun {
	let box: StatusBox
	let gate = Latch()
	var ending: AppModel.SyncStatus.Phase

	init(_ box: StatusBox, ending: AppModel.SyncStatus.Phase) {
		self.box = box
		self.ending = ending
	}

	func sync() async -> AppModel.SyncStatus {
		box.status.phase = .syncing
		await gate.wait()
		box.status.phase = ending
		if ending == .idle { box.status.lastSynced = .now }
		return box.status
	}
}

private struct PressedSyncForm: View {
	let run: SyncRun
	let spoken: Spoken
	let announcements: SyncAnnouncements

	var body: some View {
		Form {
			SyncSection(
				controls: SyncControls(status: run.box.status, syncNow: run.sync),
				present: { _ in },
				announce: { spoken.heard.append($0) },
				announcements: announcements
			)
		}
		.formStyle(.grouped)
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
		let controls = SyncControls(status: status, syncNow: {
			requests.synced += 1
			return status
		})
		return OffscreenWindow(SyncForm(section: SyncSection(controls: controls) { requests.presented.append($0) }), width: 440, height: 360)
	}

	@Test func withoutAServerTheSectionOffersSetup() async throws {
		let requests = Requests()
		let offscreen = offscreen(AppModel.SyncStatus(), requests)
		defer { offscreen.close() }

		#expect(offscreen.accessibilityElements(.button).map(\.label) == ["Set Up Sync…"])
		try offscreen.press("Set Up Sync…")
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
		try offscreen.press("Sync Now")
		try offscreen.press("Change Server…")
		try offscreen.press("Change Recovery Phrase…")
		await offscreen.pump { requests.synced > 0 && requests.presented.count == 2 }
		#expect(requests.presented == [.changeServer, .changeRecoveryPhrase])
		#expect(!offscreen.accessibilityElements(.button).contains { $0.label == "Change API Key…" })
		#expect(offscreen.accessibilityElements(.button).contains { $0.label == "Turn Off Sync…" })
	}

	@Test func syncNowReadsInProgressHidesItsSpinnerAndReadsOutEachOutcomeOnce() async throws {
		let reason = "The server could not be reached."
		let run = SyncRun(StatusBox(AppModel.SyncStatus(phase: .idle, server: "http://notes.example:8080/", lastSynced: .now)), ending: .failed(reason))
		let spoken = Spoken()
		let offscreen = OffscreenWindow(PressedSyncForm(run: run, spoken: spoken, announcements: SyncAnnouncements()), width: 440, height: 360)
		defer { offscreen.close() }
		func syncNow() async throws {
			try offscreen.press("Sync Now")
			await offscreen.pump { run.gate.isHolding && offscreen.button("Sync Now")?.isEnabled == false }
			let busy = try #require(offscreen.button("Sync Now"))
			#expect(busy.value == OnboardingLabel.busyValue)
			#expect(!offscreen.views(of: NSProgressIndicator.self).isEmpty)
			#expect(!offscreen.exposesASpinner)
			let heard = spoken.heard.count
			run.gate.release()
			await offscreen.pump { spoken.heard.count > heard }
			offscreen.pump(for: 0.05)
		}

		try await syncNow()
		#expect(spoken.heard == ["Sync failed: \(reason)"])
		#expect(offscreen.button("Sync Now")?.value != OnboardingLabel.busyValue)

		try await syncNow()
		#expect(spoken.heard == ["Sync failed: \(reason)", "Sync failed: \(reason)"])

		run.ending = .idle
		try await syncNow()
		#expect(spoken.heard == ["Sync failed: \(reason)", "Sync failed: \(reason)", "Last synced just now"])
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
