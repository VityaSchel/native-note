import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct OffscreenWindowTests {
	@Test func aWindowThatNeverReachesTheAwaitedStateIsAFailureNotASilentReturn() async {
		let offscreen = OffscreenWindow(Text("Still"), width: 120, height: 40)
		defer { offscreen.close() }

		await withKnownIssue {
			await offscreen.pump(turns: 3) { false }
		}
	}

	@Test func aWindowThatReachesTheAwaitedStateOnItsLastTurnIsNotAFailure() async {
		let offscreen = OffscreenWindow(Text("Still"), width: 120, height: 40)
		defer { offscreen.close() }
		var polls = 0

		await offscreen.pump(turns: 3) {
			polls += 1
			return polls == 4
		}

		#expect(polls == 4)
	}
}
