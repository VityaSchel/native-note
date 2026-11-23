import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct OffscreenWindowTests {
	private func turnRunLoop() {
		RunLoop.current.run(until: Date().addingTimeInterval(0.01))
	}

	@Test func aWindowThatNeverReachesTheAwaitedStateIsAFailureNotASilentReturn() async {
		let offscreen = OffscreenWindow(Text("Still"), width: 120, height: 40)
		defer { offscreen.close() }

		await withKnownIssue {
			await offscreen.pump(turns: 3) { false }
		}
	}

	@Test func closingAWindowThatCaughtASheetReleasesTheWindowAndTheSheet() async {
		weak var window: NSWindow?
		weak var sheet: NSWindow?
		do {
			let offscreen = OffscreenWindow(Color.clear.sheet(isPresented: .constant(true)) { Text("Caught").padding(40) }, catchesSheets: true)
			await offscreen.pump { offscreen.sheet != nil }
			window = offscreen.window
			sheet = offscreen.sheet
			offscreen.close()
		}
		for _ in 0 ..< 20 where window != nil || sheet != nil {
			turnRunLoop()
			await Task.yield()
		}

		#expect(window == nil)
		#expect(sheet == nil)
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
