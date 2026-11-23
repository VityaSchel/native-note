import NativeNoteKit

@MainActor
final class SyncAnnouncements {
	static let shared = SyncAnnouncements()

	private var spokenFailure: String?
	private var requestedSyncs = 0

	func phaseChanged(to phase: AppModel.SyncStatus.Phase) -> String? {
		switch phase {
		case .off, .idle:
			spokenFailure = nil
			return nil
		case .syncing:
			return nil
		case let .failed(reason):
			guard reason != spokenFailure else { return nil }
			spokenFailure = reason
			return requestedSyncs == 0 ? SyncSection.failureLine(reason) : nil
		}
	}

	func syncNow(_ sync: () async -> AppModel.SyncStatus) async -> String? {
		requestedSyncs += 1
		let status = await sync()
		requestedSyncs -= 1
		guard status.server != nil else { return nil }
		guard case let .failed(reason) = status.phase else { return SyncSection.outcomeLine(status) }
		spokenFailure = reason
		return SyncSection.failureLine(reason)
	}
}

extension AppModel {
	func statusAfterSyncing() async -> SyncStatus {
		await syncNow()
		return syncStatus
	}
}
