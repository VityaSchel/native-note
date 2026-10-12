import AppKit
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private final class Requests {
	var presented: [SecuritySettings.Sheet] = []
	var turnedOff = 0
	var turnOns: [String] = []
	var changes: [[String]] = []
	var done = 0
}

@MainActor
struct SettingsViewTests {
	private let alarm = Alarm()

	private func form(_ requests: Requests, touchIDEnabled: Bool) -> OffscreenWindow<SecurityForm> {
		OffscreenWindow(
			SecurityForm(touchIDAvailable: true, touchIDEnabled: touchIDEnabled, turnOffTouchID: { requests.turnedOff += 1 }) { requests.presented.append($0) },
			width: 440,
			height: 300
		)
	}

	private func settings(_ requests: Requests) -> SecuritySettings {
		SecuritySettings(
			touchIDAvailable: true,
			touchIDEnabled: false,
			turnOnTouchID: { password in
				requests.turnOns.append(password)
				return nil
			},
			turnOffTouchID: { requests.turnedOff += 1 },
			changePassword: { current, new in
				requests.changes.append([current, new])
				return nil
			}
		)
	}

	private func library(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
		model.appBecameActive()
		return (model, directory)
	}

	private func placeholders(_ fields: [NSSecureTextField]) -> [String] {
		fields.compactMap(\.placeholderString).sorted()
	}

	private func type<Content: View>(_ text: String, into placeholder: String, of offscreen: OffscreenWindow<Content>) throws -> NSSecureTextField {
		let field = try #require(offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == placeholder })
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	private func submitPasswordInSheet(_ text: String, of offscreen: OffscreenWindow<SettingsView>) throws {
		let sheet = try #require(offscreen.sheet)
		let field = try #require(offscreen.sheetViews(of: NSSecureTextField.self).first { $0.placeholderString == "Password" })
		try #require(sheet.makeFirstResponder(field))
		let editor = try #require(field.currentEditor())
		editor.insertText(text)
		offscreen.pump()
		editor.insertNewline(nil)
	}

	private func switchTouchIDOn(in offscreen: OffscreenWindow<SettingsView>) async throws -> NSSwitch {
		let toggle = try #require(offscreen.views(of: NSSwitch.self).first)
		try #require(toggle.state == .off)
		try #require(offscreen.sheet == nil)
		toggle.performClick(nil)
		await offscreen.pump { offscreen.sheet != nil }
		return toggle
	}

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

	@Test func switchingTouchIDOnAsksForThePasswordFirst() async throws {
		let requests = Requests()
		let offscreen = form(requests, touchIDEnabled: false)
		defer { offscreen.close() }
		let toggle = try #require(offscreen.views(of: NSSwitch.self).first)
		#expect(toggle.state == .off)

		toggle.performClick(nil)
		await offscreen.pump { !requests.presented.isEmpty }
		offscreen.pump(for: 0.05)

		#expect(requests.presented == [.turnOnTouchID])
		#expect(requests.turnedOff == 0)
		#expect(toggle.state == .off)
	}

	@Test func switchingTouchIDOffAsksNothing() async throws {
		let requests = Requests()
		let offscreen = form(requests, touchIDEnabled: true)
		defer { offscreen.close() }
		let toggle = try #require(offscreen.views(of: NSSwitch.self).first)
		#expect(toggle.state == .on)

		toggle.performClick(nil)
		await offscreen.pump { requests.turnedOff > 0 }

		#expect(requests.turnedOff == 1)
		#expect(requests.presented.isEmpty)
	}

	@Test func withoutTouchIDThereIsNoSwitch() {
		let offscreen = OffscreenWindow(
			SecurityForm(touchIDAvailable: false, touchIDEnabled: false, turnOffTouchID: {}, present: { _ in }),
			width: 440,
			height: 300
		)
		defer { offscreen.close() }

		#expect(offscreen.views(of: NSSwitch.self).isEmpty)
	}

	@Test func theTouchIDSheetAsksForThePasswordAndTurnsTouchIDOn() async throws {
		let requests = Requests()
		let offscreen = OffscreenWindow(settings(requests).content(for: .turnOnTouchID) { requests.done += 1 }, width: 360, height: 200)
		defer { offscreen.close() }
		#expect(placeholders(offscreen.views(of: NSSecureTextField.self)) == ["Password"])

		try #require(try type("correct horse", into: "Password", of: offscreen).currentEditor()).insertNewline(nil)
		await offscreen.pump { requests.done > 0 }

		#expect(requests.turnOns == ["correct horse"])
		#expect(requests.changes.isEmpty)
		#expect(requests.done == 1)
	}

	@Test func theChangePasswordSheetAsksForBothPasswordsAndChangesIt() async throws {
		let requests = Requests()
		let offscreen = OffscreenWindow(settings(requests).content(for: .changePassword) { requests.done += 1 }, width: 360, height: 260)
		defer { offscreen.close() }
		#expect(placeholders(offscreen.views(of: NSSecureTextField.self)) == ["Confirm new password", "Current password", "New password"])

		_ = try type("old password", into: "Current password", of: offscreen)
		_ = try type("new password", into: "New password", of: offscreen)
		try #require(try type("new password", into: "Confirm new password", of: offscreen).currentEditor()).insertNewline(nil)
		await offscreen.pump { requests.done > 0 }

		#expect(requests.changes == [["old password", "new password"]])
		#expect(requests.turnOns.isEmpty)
		#expect(requests.done == 1)
	}

	@Test func switchingTouchIDOnInSettingsAsksForThePasswordInASheet() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let offscreen = OffscreenWindow(SettingsView(model: model), width: 440, height: 300, catchesSheets: true)
		defer { offscreen.close() }

		let toggle = try await switchTouchIDOn(in: offscreen)

		let sheet = try #require(offscreen.sheet)
		#expect(!sheet.isVisible)
		#expect(placeholders(offscreen.sheetViews(of: NSSecureTextField.self)) == ["Password"])
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.reasons.isEmpty)

		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		try submitPasswordInSheet(workspacePassword, of: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		let glyph = try #require(offscreen.sheetViews(of: LAAuthenticationView.self).first)
		#expect(glyph.context === model.touchID.listeningContext)
		#expect(glyph.window === offscreen.sheet)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
		#expect(toggle.state == .off)

		sensor.touch()
		await offscreen.pump(turns: 4_000) { offscreen.sheet == nil && toggle.state == .on }

		#expect(offscreen.sheet == nil)
		#expect(model.isBiometricUnlockEnabled)
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(keys.storedKey == (try await workspaceKey()))
		#expect(toggle.state == .on)
	}

	@Test func lockingWhileTurningOnTouchIDClosesTheSheetAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let offscreen = OffscreenWindow(SettingsView(model: model), width: 440, height: 300, catchesSheets: true)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		_ = try await switchTouchIDOn(in: offscreen)
		try submitPasswordInSheet(workspacePassword, of: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		try #require(offscreen.sheet != nil)
		try #require(keys.storedKey != nil)

		await model.lock()
		await offscreen.pump { offscreen.sheet == nil && offscreen.views(of: NSSwitch.self).isEmpty }

		#expect(offscreen.sheet == nil)
		#expect(offscreen.views(of: NSSwitch.self).isEmpty)
		#expect(keys.storedKey == nil)

		sensor.touch()
		offscreen.pump(for: 0.05)

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
	}

	@Test func switchingTouchIDOffInSettingsTurnsItOffForTheLibrary() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await turnOnTouchID(model)
		let offscreen = OffscreenWindow(SettingsView(model: model), width: 440, height: 300, catchesSheets: true)
		defer { offscreen.close() }
		let toggle = try #require(offscreen.views(of: NSSwitch.self).first)
		#expect(toggle.state == .on)

		toggle.performClick(nil)
		await offscreen.pump { !model.isBiometricUnlockEnabled && toggle.state == .off }
		offscreen.pump(for: 0.05)

		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(toggle.state == .off)
		#expect(offscreen.sheet == nil)
	}

	private func sized(_ model: AppModel) -> (NSHostingController<SettingsView>, NSWindow) {
		let controller = NSHostingController(rootView: SettingsView(model: model))
		controller.sizingOptions = [.preferredContentSize, .minSize, .maxSize]
		let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
		window.contentViewController = controller
		return (controller, window)
	}

	private func settle(_ window: NSWindow, until done: () -> Bool) async {
		for _ in 0 ..< 400 where !done() {
			spin(window)
			await Task.yield()
		}
	}

	/// Wrapping labels size the form over several layout passes, so the size counts once it holds.
	private func settledSize(of controller: NSHostingController<SettingsView>, in window: NSWindow) async -> NSSize {
		var size = controller.preferredContentSize
		var held = 0
		for _ in 0 ..< 400 where held < 20 {
			spin(window)
			await Task.yield()
			held = controller.preferredContentSize == size ? held + 1 : 0
			size = controller.preferredContentSize
		}
		return size
	}

	private func spin(_ window: NSWindow) {
		window.contentView?.layoutSubtreeIfNeeded()
		RunLoop.current.run(until: Date().addingTimeInterval(0.005))
	}

	private func content(of window: NSWindow) -> NSSize {
		window.contentRect(forFrameRect: window.frame).size
	}

	private func isAbout(_ size: NSSize, _ expected: NSSize) -> Bool {
		abs(size.width - expected.width) <= 1 && abs(size.height - expected.height) <= 1
	}

	private func scrollViews(in root: NSView) -> [NSScrollView] {
		var found: [NSScrollView] = []
		var pending = [root]
		while let view = pending.popLast() {
			if let scroll = view as? NSScrollView { found.append(scroll) }
			pending.append(contentsOf: view.subviews)
		}
		return found
	}

	@Test func theSettingsWindowSizesToTheFormAndToTheLockedMessageAndCannotBeResizedAway() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let (controller, window) = sized(model)
		defer { window.contentViewController = nil }
		await settle(window) { controller.preferredContentSize.height > 0 && !scrollViews(in: controller.view).isEmpty }

		let unlocked = await settledSize(of: controller, in: window)
		let form = try #require(scrollViews(in: controller.view).first)
		#expect(unlocked.width == SettingsView.width)
		#expect(unlocked.height != SettingsView.lockedHeight)
		#expect(isAbout(window.contentMinSize, unlocked))
		#expect(isAbout(window.contentMaxSize, unlocked))
		#expect(isAbout(content(of: window), unlocked))
		#expect(try #require(form.documentView).frame.height <= form.contentSize.height + 0.5)
		#expect(form.contentSize.height >= unlocked.height - 1)

		let locked = NSSize(width: SettingsView.width, height: SettingsView.lockedHeight)
		await model.lock()
		await settle(window) { isAbout(window.contentMaxSize, locked) && isAbout(content(of: window), locked) }

		#expect(controller.preferredContentSize == locked)
		#expect(isAbout(window.contentMinSize, locked))
		#expect(isAbout(window.contentMaxSize, locked))
		#expect(isAbout(content(of: window), locked))
		window.setContentSize(NSSize(width: 700, height: 120))
		await settle(window) { false }
		#expect(isAbout(content(of: window), locked))

		await model.submit(password: workspacePassword)
		await settle(window) { controller.preferredContentSize == unlocked && isAbout(content(of: window), unlocked) }

		#expect(model.phase == .unlocked)
		#expect(controller.preferredContentSize == unlocked)
		#expect(isAbout(content(of: window), unlocked))
		let reopened = try #require(scrollViews(in: controller.view).first)
		#expect(try #require(reopened.documentView).frame.height <= reopened.contentSize.height + 0.5)
	}

	@Test func theLockedMessageAndTheFormEachHaveOneSize() {
		func range(_ model: AppModel) -> (NSSize, NSSize) {
			let host = NSHostingView(rootView: SettingsView(model: model))
			return (host.fittingSize, host.intrinsicContentSize)
		}

		let (lockedFit, lockedIntrinsic) = range(.previewingFirstRun)
		#expect(lockedFit == NSSize(width: SettingsView.width, height: SettingsView.lockedHeight))
		#expect(lockedIntrinsic == lockedFit)
		let (formFit, formIntrinsic) = range(.previewing([]))
		#expect(formFit.width == SettingsView.width)
		#expect(isAbout(formIntrinsic, formFit))
		#expect(formFit.height != SettingsView.lockedHeight)
	}

	@Test func lockingTakesTheSettingsAway() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let offscreen = OffscreenWindow(SettingsView(model: model), width: 440, height: 300)
		defer { offscreen.close() }
		try #require(!offscreen.views(of: NSSwitch.self).isEmpty)

		await model.lock()
		await offscreen.pump { offscreen.views(of: NSSwitch.self).isEmpty }

		#expect(offscreen.views(of: NSSwitch.self).isEmpty)
	}
}
