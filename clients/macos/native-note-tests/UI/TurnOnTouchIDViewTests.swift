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
	var spoken: [AttributedString] = []
	var announced: [String] { spoken.map { String($0.characters) } }
}

@MainActor @Suite(.takesFocus, .scratch, .timeLimit(.minutes(10)))
struct TurnOnTouchIDViewTests {
	private let alarm = Alarm()

	private func offscreen(_ calls: Calls, turnOn: @escaping (String) async -> AppModel.Failure?) -> OffscreenWindow<TurnOnTouchIDView> {
		OffscreenWindow(
			TurnOnTouchIDView(turnOn: { password in
				calls.passwords.append(password)
				let reply = await turnOn(password)
				calls.replies.append(reply)
				return reply
			}, done: { calls.done += 1 }, announce: { calls.spoken.append($0) }),
			width: 360,
			height: 160
		)
	}

	private func sheet(_ calls: Calls, for model: AppModel) -> OffscreenWindow<TurnOnTouchIDSheet> {
		OffscreenWindow(TurnOnTouchIDSheet(model: model, calls: calls), width: 360, height: 200)
	}

	private func isWorking(_ offscreen: OffscreenWindow<some View>) -> Bool {
		!offscreen.views(of: NSProgressIndicator.self).isEmpty
	}

	@Test func returnSendsThePasswordOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try offscreen.submit("correct horse", in: "Password:")
		await offscreen.pump { calls.done > 0 }

		#expect(calls.passwords == ["correct horse"])
		#expect(calls.done == 1)
	}

	@Test func whileThePasswordIsCheckedContinueReadsInProgressAndTheSpinnerIsHidden() async throws {
		let calls = Calls()
		let checking = Latch()
		let offscreen = offscreen(calls) { _ in
			await checking.wait()
			return nil
		}
		defer { offscreen.close() }
		defer { checking.release() }

		try offscreen.submit("correct horse", in: "Password:")
		await offscreen.pump { checking.isHolding }
		offscreen.pump(for: 0.05)

		let button = try #require(offscreen.button("Continue"))
		#expect(!button.isEnabled)
		#expect(button.value == OnboardingLabel.busyValue)
		#expect(isWorking(offscreen))
		#expect(!offscreen.exposesASpinner)

		checking.release()
		await offscreen.pump { calls.done > 0 }
	}

	@Test func anEmptyPasswordSendsNothing() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls) { _ in nil }
		defer { offscreen.close() }

		try offscreen.submit("", in: "Password:")
		offscreen.pump(for: 0.1)

		#expect(calls.passwords.isEmpty)
		#expect(calls.done == 0)
	}

	@Test func theRightPasswordListensInTheSheetAndATouchTurnsTouchIDOn() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		#expect(!isWorking(offscreen))

		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		let glyph = try #require(offscreen.glyphs.first)
		#expect(glyph.context === model.touchID.listeningContext)
		#expect(glyph.accessibilityLabel() == TurnOnTouchIDView.touchIDLabel)
		#expect(!glyph.isHiddenOrHasHiddenAncestor)
		#expect(sequence(first: glyph as NSView, next: \.superview).allSatisfy { $0.alphaValue == 1 && ($0.layer?.opacity ?? 1) == 1 })
		#expect(keys.contexts.first === glyph.context)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
		#expect(offscreen.secureField("Password:") == nil)
		#expect(!isWorking(offscreen))
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine])

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

	@Test func whileItWaitsForTheTouchOnlyCancelShowsAndTheGlyphSitsMidway() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let offscreen = OffscreenWindow(TurnOnTouchIDSheet(model: model, calls: Calls()), width: 380, height: 320)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		#expect(offscreen.accessibilityElements(.button).map(\.label) == ["Cancel", "Continue"])

		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		#expect(offscreen.accessibilityElements(.button).map(\.label) == ["Cancel"])
		let title = try #require(offscreen.accessibilityElements().first { $0.label == "Turn On Touch ID Unlock" || $0.value == "Turn On Touch ID Unlock" }).frame
		let line = try #require(offscreen.accessibilityElements(.staticText).first { $0.value == TurnOnTouchIDView.touchIDLine || $0.label == TurnOnTouchIDView.touchIDLine }).frame
		let glyph = offscreen.onScreen(try #require(offscreen.glyphs.first))
		let cancel = try #require(offscreen.accessibilityElements(.button).first).frame
		#expect(abs((title.minY - glyph.maxY) - (line.minY - cancel.maxY)) <= 2, "\(title) \(glyph) \(line) \(cancel)")
		sensor.touch()
	}

	@Test func aWrongPasswordStaysOpenWithTheFieldCleared() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try offscreen.submit("a guess", in: "Password:")
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && field.stringValue.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.wrongPassword])
		#expect(field.stringValue.isEmpty)
		#expect(calls.announced == ["Wrong password."])
		#expect(calls.spoken.map(\.accessibilitySpeechAnnouncementPriority) == [.high])
		#expect(!isWorking(offscreen))
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func escapeCancelsWithoutTurningAnythingOn() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }
		_ = try offscreen.type(workspacePassword, into: "Password:")

		#expect(try offscreen.pressEscape())
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(calls.passwords.isEmpty)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func aWrongFingerInTheSheetWaitsForAClickOnTryTouchIDAgain() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		keys.reply(with: .miss)
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }

		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { offscreen.tryAgainButton != nil && offscreen.glyphs.isEmpty }

		let button = try #require(offscreen.tryAgainButton)
		#expect(model.touchID == .needsClick(after: .miss))
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(calls.done == 0)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID didn't match."])

		keys.reply(with: .key)
		button.press()
		await offscreen.pump { calls.done > 0 }

		#expect(calls.done == 1)
		#expect(keys.contexts.count == 2)
		#expect(model.isBiometricUnlockEnabled)
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID didn't match.", TurnOnTouchIDView.touchIDLine])
	}

	@Test func anInterruptedTouchInTheSheetWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		keys.reply(with: .cancel)
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }

		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { offscreen.tryAgainButton != nil }

		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID stopped."])
		#expect(calls.done == 0)
		#expect(keys.storedKey != nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func leavingTheAppAfterAnInterruptedTouchSaysNothingFromTheBackgroundAndRepeatsTheInstructionOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		keys.reply(with: .cancel)
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { offscreen.tryAgainButton != nil }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)

		model.appResignedActive()
		await offscreen.pump { offscreen.tryAgainButton == nil }
		offscreen.pump(for: 0.05)

		#expect(model.touchID == .paused(.inBackground))
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID stopped."])

		model.appBecameActive()
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		offscreen.pump(for: 0.05)

		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID stopped.", TurnOnTouchIDView.touchIDLine])
		keys.reply(with: .key)
		sensor.touch()
		await offscreen.pump { calls.done > 0 }
		#expect(model.isBiometricUnlockEnabled)
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine, "Touch ID stopped.", TurnOnTouchIDView.touchIDLine])
	}

	@Test func leavingTheAppDimsTheSheetsGlyphAndReturningListensAgain() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		let first = try #require(offscreen.glyphs.first?.context)

		model.appResignedActive()
		await offscreen.pump { offscreen.glyphs.isEmpty }

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		#expect(offscreen.views(of: TouchIDGlyphView.self).first?.symbol != nil)
		#expect(offscreen.accessibilityElements(.staticText).map(\.value).contains(TurnOnTouchIDView.touchIDLine))

		model.appBecameActive()
		await offscreen.pump { keys.contexts.count == 2 }
		#expect(offscreen.glyphs.first?.context === keys.contexts.last)

		sensor.touch()
		await offscreen.pump { calls.done > 0 }
		#expect(model.isBiometricUnlockEnabled)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
		#expect(calls.announced == [TurnOnTouchIDView.touchIDLine])
	}

	@Test func cancelWhileTouchIDListensClosesTheSheetWithItOff() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		defer { sensor.touch() }
		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }
		let listening = try #require(offscreen.glyphs.first?.context)

		#expect(try offscreen.pressEscape())
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
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)
		defer { sensor.touch() }
		try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { sensor.isWaiting }

		offscreen.close()
		try await settle { !calls.replies.isEmpty }

		#expect(calls.replies == [nil])
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func aKeychainFailureStaysOpenWithThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		keys.failWrites()
		let calls = Calls()
		let offscreen = offscreen(calls, turnOn: model.enableBiometricUnlock(password:))
		defer { offscreen.close() }

		let field = try offscreen.submit(workspacePassword, in: "Password:")
		await offscreen.pump(turns: 4_000) { !calls.replies.isEmpty && !isWorking(offscreen) }

		#expect(calls.replies == [.unexpected("Touch ID unlock could not be turned on. \(KeychainFailure(status: errSecNotAvailable).message)")])
		#expect(calls.announced == ["Touch ID unlock could not be turned on. \(KeychainFailure(status: errSecNotAvailable).message)"])
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
		let (model, _) = try await Workspace(alarm: alarm).unlocked(keys)
		model.appBecameActive()
		let calls = Calls()
		let offscreen = sheet(calls, for: model)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)

		try offscreen.submit(workspacePassword, in: "Password:")
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
			touchID: TouchIDControls(model),
			announce: { calls.spoken.append($0) }
		)
	}
}
