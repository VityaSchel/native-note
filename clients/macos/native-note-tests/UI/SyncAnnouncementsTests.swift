import Foundation
import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct SyncAnnouncementsTests {
	private let reason = "The server could not be reached."
	private let server = "http://notes.example:8080/"

	@Test func aFailureNobodyAskedForIsReadOnceUntilASyncWorks() {
		let announcements = SyncAnnouncements()

		#expect(announcements.phaseChanged(to: .syncing) == nil)
		#expect(announcements.phaseChanged(to: .failed(reason)) == "Sync failed: \(reason)")
		#expect(announcements.phaseChanged(to: .failed(reason)) == nil)
		#expect(announcements.phaseChanged(to: .syncing) == nil)
		#expect(announcements.phaseChanged(to: .failed(reason)) == nil)
		#expect(announcements.phaseChanged(to: .failed("The server's answer did not arrive.")) == "Sync failed: The server's answer did not arrive.")
		#expect(announcements.phaseChanged(to: .idle) == nil)
		#expect(announcements.phaseChanged(to: .failed(reason)) == "Sync failed: \(reason)")
	}

	@Test func aFailedSyncNowIsReadOnceWhetherAWindowSeesTheFailureBeforeOrAfterItReturns() async {
		let seenFirst = SyncAnnouncements()
		var heardWhileAsked: [String] = []
		let outcome = await seenFirst.syncNow {
			for phase in [AppModel.SyncStatus.Phase.syncing, .failed(reason), .failed(reason)] {
				if let line = seenFirst.phaseChanged(to: phase) { heardWhileAsked.append(line) }
			}
			return AppModel.SyncStatus(phase: .failed(reason), server: server)
		}

		#expect(outcome == "Sync failed: \(reason)")
		#expect(heardWhileAsked.isEmpty)
		#expect(seenFirst.phaseChanged(to: .failed(reason)) == nil)

		let seenAfter = SyncAnnouncements()
		#expect(await seenAfter.syncNow { AppModel.SyncStatus(phase: .failed(reason), server: server) } == "Sync failed: \(reason)")
		#expect(seenAfter.phaseChanged(to: .failed(reason)) == nil)
	}

	@Test func aSyncNowThatFailsForTheReasonAlreadyReadIsReadAgain() async {
		let announcements = SyncAnnouncements()
		#expect(announcements.phaseChanged(to: .failed(reason)) != nil)

		let outcome = await announcements.syncNow {
			#expect(announcements.phaseChanged(to: .syncing) == nil)
			#expect(announcements.phaseChanged(to: .failed(reason)) == nil)
			return AppModel.SyncStatus(phase: .failed(reason), server: server)
		}

		#expect(outcome == "Sync failed: \(reason)")
	}

	@Test func aSyncNowThatWorksSaysWhenAndWhatItLeftBehind() async {
		let announcements = SyncAnnouncements()
		let problem = "A note is larger than 1 MB, so it stays on this Mac until it is shorter."

		#expect(await announcements.syncNow { AppModel.SyncStatus(phase: .idle, server: server, lastSynced: .now) } == "Last synced just now")
		#expect(await announcements.syncNow { AppModel.SyncStatus(phase: .idle, server: server, lastSynced: .now, problems: [problem]) } == "Last synced just now. \(problem)")
	}

	@Test func aSyncNowThatLockOrTurningSyncOffStoppedSaysNothing() async {
		let announcements = SyncAnnouncements()
		let cancelled = "The server could not be reached. cancelled"

		#expect(await announcements.syncNow { AppModel.SyncStatus() } == nil)
		#expect(await announcements.syncNow { AppModel.SyncStatus(phase: .failed(cancelled)) } == nil)
		#expect(announcements.phaseChanged(to: .failed(cancelled)) == "Sync failed: \(cancelled)")
	}
}
