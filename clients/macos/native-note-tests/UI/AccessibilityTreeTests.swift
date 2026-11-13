import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct AccessibilityTreeTests {
	@Test func aTreeReadInsideAnotherLeavesEnhancedAccessibilityOnUntilTheOuterOneEnds() {
		let before = EnhancedAccessibility.readers
		var seen: [Int] = []
		var stayedOn: [Bool] = []

		EnhancedAccessibility.reading {
			EnhancedAccessibility.reading { seen.append(EnhancedAccessibility.readers) }
			seen.append(EnhancedAccessibility.readers)
			stayedOn.append(EnhancedAccessibility.isOn)
		}

		#expect(seen == [before + 2, before + 1])
		#expect(stayedOn == [true])
		#expect(EnhancedAccessibility.readers == before)
		#expect(EnhancedAccessibility.isOn == (before > 0))
	}

	@Test func aWindowsElementsAreReadWhileAnotherReadIsStillGoing() {
		let offscreen = OffscreenWindow(Button("Unlock") {}, width: 200, height: 80)
		defer { offscreen.close() }
		offscreen.pump(for: 0.05)

		let labels = EnhancedAccessibility.reading {
			_ = offscreen.accessibilityElements(.button)
			return offscreen.accessibilityElements(.button).map(\.label)
		}

		#expect(labels == ["Unlock"])
	}
}
