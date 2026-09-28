import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Security
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
private final class Calls {
	var passwords: [String] = []
	var replies: [AppModel.Failure?] = []
	var done = 0
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct TurnOnTouchIDViewTests {
	private let alarm = Alarm()

	private func offscreen(_ calls: Calls, turnOn: @escaping (String) async -> AppModel.Failure?) -> OffscreenWindow<TurnOnTouchIDView> {
		OffscreenWindow(
			TurnOnTouchIDView(turnOn: { password in
				calls.passwords.append(password)
				let reply = await turnOn(password)
				calls.replies.append(reply)
				return reply
			}, done: { calls.done += 1 }),
			width: 360,
			height: 160
		)
	}

	private func library(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
		model.appBecameActive()
		return (model, directory)
	}

	private func sheet(_ calls: Calls, for model: AppModel) -> OffscreenWindow<TurnOnTouchIDSheet> {
		OffscreenWindow(TurnOnTouchIDSheet(model: model, calls: calls), width: 360, height: 200)
	}

	private func glyphs(in offscreen: OffscreenWindow<some View>) -> [LAAuthenticationView] {
		offscreen.views(of: LAAuthenticationView.self)
	}

	private func tryAgainButton(in offscreen: OffscreenWindow<some View>) -> NSButton? {
		offscreen.views(of: NSButton.self).first { $0.title == TryTouchIDAgainButton.title }
	}

	private func passwordField(in offscreen: OffscreenWindow<some View>) -> NSSecureTextField? {
		offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == "Password" }
	}

	private func type(_ text: String, in offscreen: OffscreenWindow<some View>) throws -> NSSecureTextField {
		let field = try #require(passwordField(in: offscreen))
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	@discardableResult
	private func submit(_ text: String, in offscreen: OffscreenWindow<some View>) throws -> NSSecureTextField {
		let field = try type(text, in: offscreen)
		try #require(field.currentEditor()).insertNewline(nil)
		return field
	}

	private func pressEscape(in offscreen: OffscreenWindow<some View>) throws -> Bool {
		let escape = try #require(
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				characters: "\u{1b}",
				charactersIgnoringModifiers: "\u{1b}",
				isARepeat: false,
				keyCode: 53
			)
		)
		let handled = offscreen.host.performKeyEquivalent(with: escape)
		offscreen.pump()
		return handled
	}

	private func isWorking(_ offscreen: OffscreenWindow<some View>) -> Bool {
		!offscreen.views(of: NSProgressIndicator.self).isEmpty
	}

	@Test func returnSendsThePasswordOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try submit("correct horse", in: offscreen)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.passwords == ["correct horse"])
		#expect(calls.done == 1)
	}

	@Test func anEmptyPasswordSendsNothing() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try submit("", in: offscreen)
		await offscreen.pump(turns: 20) { false }

		#expect(calls.passwords.isEmpty)
		#expect(calls.done == 0)
	}

	@Test func theRightPasswordListensInTheSheetAndATouchTurnsTouchIDOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		#expect(!isWorking(offscreen))

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		let glyph = try #require(glyphs(in: offscreen).first)
		#expect(glyph.context === model.touchID.listeningContext)
		#expect(glyph.accessibilityLabel() == TurnOnTouchIDView.touchIDLabel)
		#expect(!glyph.isHiddenOrHasHiddenAncestor)
		#expect(sequence(first: glyph as NSView, next: \.superview).allSatisfy { $0.alphaValue == 1 && ($0.layer?.opacity ?? 1) == 1 })
		#expect(keys.contexts.first === glyph.context)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
		#expect(passwordField(in: offscreen) == nil)
		#expect(!isWorking(offscreen))
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)

		sensor.touch()
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.replies == [nil])
		#expect(model.isBiometricUnlockEnabled)
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(keys.storedKey == (try await workspaceKey()))
		#expect(keys.contexts.allSatisfy(isInvalidated))
		#expect(model.failure == nil)
	}

	@Test func aWrongPasswordStaysOpenWithTheFieldCleared() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try submit("a guess", in: offscreen)
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && field.stringValue.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.wrongPassword])
		#expect(field.stringValue.isEmpty)
		#expect(!isWorking(offscreen))
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func escapeCancelsWithoutTurningAnythingOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }
		_ = try type(workspacePassword, in: offscreen)

		#expect(try pressEscape(in: offscreen))
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.passwords.isEmpty)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func aWrongFingerInTheSheetWaitsForAClickOnTryTouchIDAgain() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { tryAgainButton(in: offscreen) != nil }

		let button = try #require(tryAgainButton(in: offscreen))
		#expect(model.touchID == .needsClick(after: .miss))
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)

		keys.reply(with: .key)
		button.performClick(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(keys.contexts.count == 2)
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func anInterruptedTouchInTheSheetWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { tryAgainButton(in: offscreen) != nil }

		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(calls.done == 0)
		#expect(keys.storedKey != nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func leavingTheAppDimsTheSheetsGlyphAndReturningListensAgain() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		let first = try #require(glyphs(in: offscreen).first?.context)

		model.appResignedActive()
		await offscreen.pump { glyphs(in: offscreen).isEmpty }

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		#expect(offscreen.views(of: TouchIDGlyphView.self).first?.symbol != nil)
		#expect(offscreen.accessibilityElements(.staticText).map(\.value).contains(TurnOnTouchIDView.touchIDLine))

		model.appBecameActive()
		await offscreen.pump { keys.contexts.count == 2 }
		#expect(glyphs(in: offscreen).first?.context === keys.contexts.last)

		sensor.touch()
		await offscreen.pump { calls.done > 0 }
		#expect(model.isBiometricUnlockEnabled)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
	}

	@Test func cancelWhileTouchIDListensClosesTheSheetWithItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		defer { sensor.touch() }
		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		let listening = try #require(glyphs(in: offscreen).first?.context)

		#expect(try pressEscape(in: offscreen))
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.replies == [nil])
		#expect(isInvalidated(listening))
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func closingTheSheetWhileTouchIDListensLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		defer { sensor.touch() }
		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		offscreen.close()
		await settle { !calls.replies.isEmpty }

		#expect(calls.replies == [nil])
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func aKeychainFailureStaysOpenWithThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.failWrites()
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.unexpected("Touch ID unlock could not be turned on. \(KeychainFailure(status: errSecNotAvailable).message)")])
		#expect(field.stringValue == workspacePassword)
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func eachSheetStateSaysWhatTouchIDIsDoing() {
		func line(_ state: AppModel.TouchID) -> String? {
			TouchIDStatus.line(for: state, listening: TurnOnTouchIDView.touchIDLine)
		}

		#expect(line(.listening(LAContext())) == TurnOnTouchIDView.touchIDLine)
		#expect(line(.paused(.inBackground)) == TurnOnTouchIDView.touchIDLine)
		#expect(line(.needsClick(after: .miss)) == "Touch ID didn't match.")
		#expect(line(.needsClick(after: .cancel)) == "Touch ID stopped.")
		#expect(line(.hidden) == nil)
	}

	@Test func lockingWhileTouchIDListensLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)

		try submit(workspacePassword, in: offscreen)
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		await model.lock()
		sensor.touch()
		await offscreen.pump { calls.done > 0 }

		#expect(calls.replies == [nil])
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
	}
}

private struct TurnOnTouchIDSheet: View {
	let model: AppModel
	let calls: Calls

	var body: some View {
		TurnOnTouchIDView(
			turnOn: { password in
				calls.passwords.append(password)
				let reply = await model.enableBiometricUnlock(password: password)
				calls.replies.append(reply)
				return reply
			},
			done: { calls.done += 1 },
			touchID: TouchIDControls(model)
		)
	}
}
