import NativeNoteKit
import SwiftUI

/// The toolbar's Sync Now: turns while syncing, and shows a warning with the reason after a failure.
struct SyncButton: View {
	let status: AppModel.SyncStatus
	let sync: () -> Void

	var body: some View {
		Button(action: sync) {
			Label("Sync Now", systemImage: symbol)
				.symbolEffect(.rotate, isActive: status.phase == .syncing)
		}
		.help(help)
		.disabled(status.phase == .syncing)
	}

	var symbol: String {
		if case .failed = status.phase { return "exclamationmark.arrow.triangle.2.circlepath" }
		return "arrow.triangle.2.circlepath"
	}

	var help: String {
		if case let .failed(reason) = status.phase { return "Sync failed: \(reason)" }
		return SyncSection.statusLine(status)
	}
}

#if DEBUG
	#Preview("Sync button") {
		HStack {
			SyncButton(status: AppModel.SyncStatus(phase: .idle, server: "http://notes.example:8080/", lastSynced: .now)) {}
			SyncButton(status: AppModel.SyncStatus(phase: .syncing, server: "http://notes.example:8080/")) {}
			SyncButton(status: AppModel.SyncStatus(phase: .failed("The server could not be reached."), server: "http://notes.example:8080/")) {}
		}
		.padding()
	}
#endif
