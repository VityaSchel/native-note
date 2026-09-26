import AppKit
import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
private final class Switches {
	var values: [Bool] = []
}

@MainActor
struct SettingsViewTests {
	@Test func aLockedLibraryShowsNoSettings() {
		let settings = SettingsView(model: .previewingFirstRun)
		let offscreen = OffscreenWindow(settings, width: 440, height: 300)
		defer { offscreen.close() }

		#expect(!settings.isAvailable)
		#expect(offscreen.views(of: NSSwitch.self).isEmpty)
	}

	@Test func anUnlockedLibraryShowsItsSettings() {
		#expect(SettingsView(model: .previewing([])).isAvailable)
	}

	@Test func theTouchIDSwitchTurnsItOnAndOff() async throws {
		let switches = Switches()
		for enabled in [false, true] {
			let offscreen = OffscreenWindow(
				SecuritySettings(touchIDAvailable: true, touchIDEnabled: enabled, setTouchID: { switches.values.append($0) }, changePassword: { _, _ in nil }),
				width: 440,
				height: 300
			)
			defer { offscreen.close() }
			let toggle = try #require(offscreen.views(of: NSSwitch.self).first)
			#expect(toggle.state == (enabled ? .on : .off))

			toggle.performClick(nil)
			await offscreen.pump { switches.values.count == (enabled ? 2 : 1) }
		}

		#expect(switches.values == [true, false])
	}

	@Test func withoutTouchIDThereIsNoSwitch() {
		let offscreen = OffscreenWindow(
			SecuritySettings(touchIDAvailable: false, touchIDEnabled: false, setTouchID: { _ in }, changePassword: { _, _ in nil }),
			width: 440,
			height: 300
		)
		defer { offscreen.close() }

		#expect(offscreen.views(of: NSSwitch.self).isEmpty)
	}
}
