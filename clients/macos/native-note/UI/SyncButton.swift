import NativeNoteKit
import SwiftUI

struct SyncButton: View {
	enum Motion {
		case still
		case turning
		case pulsing
	}

	let status: AppModel.SyncStatus
	let sync: () async -> AppModel.SyncStatus
	var announce: (String) -> Void = VoiceOver.announce
	var announcements = SyncAnnouncements.shared
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		let motion = Self.motion(for: status.phase, reduceMotion: reduceMotion)
		TimelineView(.everyMinute) { timeline in
			Button(action: syncNow) {
				Label("Sync Now", systemImage: symbol)
					.symbolEffect(.rotate, isActive: motion == .turning)
					.symbolEffect(.pulse.wholeSymbol, isActive: motion == .pulsing)
			}
			.accessibilityValue(Text(value(at: timeline.date)))
			.disabled(status.phase == .syncing)
		}
	}

	private func syncNow() {
		Task { if let outcome = await announcements.syncNow(sync) { announce(outcome) } }
	}

	static func motion(for phase: AppModel.SyncStatus.Phase, reduceMotion: Bool) -> Motion {
		guard phase == .syncing else { return .still }
		return reduceMotion ? .pulsing : .turning
	}

	var symbol: String {
		if case .failed = status.phase { return "exclamationmark.arrow.triangle.2.circlepath" }
		return "arrow.triangle.2.circlepath"
	}

	func value(at now: Date) -> String {
		if case let .failed(reason) = status.phase { return SyncSection.failureLine(reason) }
		return status.phase == .syncing ? OnboardingLabel.busyValue : SyncSection.statusLine(status, now: now)
	}
}

#if DEBUG
	#Preview("Sync button") {
		HStack {
			SyncButton(status: AppModel.SyncStatus(phase: .idle, server: "http://notes.example:8080/", lastSynced: .now)) { AppModel.SyncStatus() }
			SyncButton(status: AppModel.SyncStatus(phase: .syncing, server: "http://notes.example:8080/")) { AppModel.SyncStatus() }
			SyncButton(status: AppModel.SyncStatus(phase: .failed("The server could not be reached."), server: "http://notes.example:8080/")) { AppModel.SyncStatus() }
		}
		.padding()
	}

	#Preview("Sync button, Reduce Motion") {
		SyncButton(status: AppModel.SyncStatus(phase: .syncing, server: "http://notes.example:8080/")) { AppModel.SyncStatus() }
			.padding()
			.environment(\._accessibilityReduceMotion, true)
	}
#endif
