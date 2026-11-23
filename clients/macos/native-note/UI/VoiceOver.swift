import AppKit
import SwiftUI

nonisolated enum VoiceOver {
	static func announce(_ line: String) {
		send(line, priority: .high)
	}

	static func post(_ line: AttributedString) {
		let priority: NSAccessibilityPriorityLevel = switch line.runs.first?.accessibilitySpeechAnnouncementPriority {
		case .high: .high
		case .low: .low
		default: .medium
		}
		send(String(line.characters), priority: priority)
	}

	static func aboveFocusChanges(_ line: String) -> AttributedString {
		var spoken = AttributedString(line)
		spoken.accessibilitySpeechAnnouncementPriority = .high
		return spoken
	}

	static func afterFocusSpeech(_ line: String) -> AttributedString {
		var spoken = AttributedString(line)
		spoken.accessibilitySpeechAnnouncementPriority = .low
		return spoken
	}

	private static let afterTheActionsOwnFeedback: TimeInterval = 0.3

	private static func send(_ line: String, priority: NSAccessibilityPriorityLevel) {
		let level = priority.rawValue
		DispatchQueue.main.asyncAfter(deadline: .now() + afterTheActionsOwnFeedback) {
			MainActor.assumeIsolated {
				NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: line, .priority: level])
			}
		}
	}
}
