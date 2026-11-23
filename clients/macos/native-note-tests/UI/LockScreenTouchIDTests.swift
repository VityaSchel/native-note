import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.takesFocus, .scratch, .timeLimit(.minutes(10)))
struct LockScreenTouchIDTests {
	private let alarm = Alarm()
	private let shaking = Alarm()
	private let sensor = Sensor()
	private let opening = Latch()

	private func library(holdingSearch: Bool = false) -> Workspace {
		Workspace(holding: ["kayak", "canoe"]) { [alarm, shaking, opening] directory, keys in
			AppModel.testing(
				in: directory,
				scheduler: alarm.scheduler,
				searchNotes: { store, text in
					if holdingSearch { await opening.wait() }
					return try await store.search(text)
				},
				keyStore: keys,
				shakeTimer: shaking.sleep
			)
		}
	}

	private func window(showing model: AppModel, watching keys: FakeKeyStore, spoken: Spoken = Spoken(), reduceMotion: Bool = false) -> OffscreenWindow<some View> {
		let offscreen = OffscreenWindow(
			ContentView(exchange: LibraryExchange(model: model), announce: { spoken.heard.append($0) })
				.environment(\._accessibilityReduceMotion, reduceMotion),
			width: 720,
			height: 640
		)
		sensor.watch(keys, in: offscreen.window)
		return offscreen
	}

	private func line(in offscreen: OffscreenWindow<some View>) -> String? {
		offscreen.accessibilityElements(.staticText).map(\.value).first { $0 == UnlockView.touchIDLine || $0 == UnlockView.touchIDStoppedLine }
	}

	private func sideways<Content: View>(_ travel: Travel<Content>, in offscreen: OffscreenWindow<Content>, for seconds: TimeInterval) async -> [CGFloat] {
		let started = Date()
		await offscreen.pump(turns: 8_000) { Date().timeIntervalSince(started) > seconds }
		#expect(travel.offsets.allSatisfy { $0.dy == 0 } && travel.offset().dy == 0)
		return travel.offsets.map(\.dx) + [travel.offset().dx]
	}

	@Test func lockingListensThroughAGlyphPairedWithTheModelsAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }

		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		let glyph = try #require(offscreen.glyphs.first)
		let password = try #require(offscreen.secureField("Password"))
		#expect(offscreen.glyphs.count == 1)
		#expect(glyph.context === model.touchID.listeningContext)
		#expect(!glyph.isAccessibilityElement())
		#expect(!glyph.isHiddenOrHasHiddenAncestor)
		#expect(isBelow(glyph, password))
		#expect(offscreen.onScreen(password).contains(offscreen.onScreen(glyph)))
		#expect(keys.contexts.count == 1)
		#expect(keys.contexts.first === glyph.context)
		#expect(keys.reasons == ["unlock your notes"])
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
		#expect(model.phase == .locked)

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
	}

	@Test func aTouchUnlocksWithoutAClick() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }

		#expect(model.phase == .unlocked)
		#expect(Set(model.notes.map(\.body)) == ["kayak", "canoe"])
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(keys.contexts.allSatisfy(isInvalidated))
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
	}

	@Test func anotherAppInFrontStopsListeningAndReturningListensThroughAFreshGlyph() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(offscreen.glyphs.first?.context)

		model.appResignedActive()
		await offscreen.pump { offscreen.glyphs.isEmpty }

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		#expect(offscreen.glyphs.isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		model.appBecameActive()
		await offscreen.pump { keys.contexts.count == 2 }

		let second = try #require(offscreen.glyphs.first?.context)
		#expect(second !== first)
		#expect(keys.contexts.last === second)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
	}

	@Test func aWrongFingerShakesTheFieldAndAFreshGlyphListensOnlyOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let spoken = Spoken()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys, spoken: spoken)
		defer { offscreen.close() }
		keys.reply(with: .miss)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(offscreen.glyphs.first?.context)
		let field = try offscreen.type("corr", into: "Password")
		let travel = Travel(of: field, in: offscreen)
		defer { travel.stop() }

		sensor.touch()
		await offscreen.pump { model.touchID == .paused(.shaking) && offscreen.glyphs.isEmpty }
		let offsets = await sideways(travel, in: offscreen, for: 0.6)

		#expect(offsets.contains { abs($0) > 0.5 })
		#expect(offsets.allSatisfy { abs($0) <= ShakeEffect.amplitude + 0.01 })
		#expect(offsets.last == 0)
		#expect(model.touchID == .paused(.shaking))
		#expect(offscreen.glyphs.isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(offscreen.tryAgainButton == nil)
		#expect(keys.contexts.count == 1)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(model.failure == nil)
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement])

		try await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && sensor.isWaiting }
		#expect(await shaking.requested == [.milliseconds(400)])

		let again = try #require(offscreen.glyphs.first?.context)
		#expect(again !== first)
		#expect(keys.contexts.last === again)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(field.stringValue == "corr")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 4, length: 0))
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement])
		keys.reply(with: .key)
		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
	}

	@Test func withReduceMotionAWrongFingerDimsTheFieldInPlaceAndAFreshGlyphListensOnlyOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let spoken = Spoken()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys, spoken: spoken, reduceMotion: true)
		defer { offscreen.close() }
		keys.reply(with: .miss)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(offscreen.glyphs.first?.context)
		let field = try offscreen.type("corr", into: "Password")
		let travel = Travel(of: field, in: offscreen)
		defer { travel.stop() }
		let box = offscreen.host.convert(field.bounds, from: field)
		let fill = NSPoint(x: box.maxX - 8, y: box.midY)
		#expect(try offscreen.opacity(at: fill) > 0.99)

		sensor.touch()
		await offscreen.pump { model.touchID == .paused(.shaking) && offscreen.glyphs.isEmpty }
		let opacities = try offscreen.opacities(at: fill, steppingFrames: 72, every: 1.0 / 120)

		#expect(try #require(opacities.min()) < 0.6)
		#expect(try #require(opacities.last) > 0.99)
		#expect(travel.offsets.allSatisfy { $0.dx == 0 && $0.dy == 0 })
		#expect(travel.offset().dx == 0 && travel.offset().dy == 0)
		#expect(model.touchID == .paused(.shaking))
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement])

		try await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && sensor.isWaiting }
		let again = try #require(offscreen.glyphs.first?.context)
		#expect(again !== first)
		#expect(field.stringValue == "corr")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 4, length: 0))
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement])
		keys.reply(with: .key)
		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
	}

	@Test func voiceOverHearsEachWrongFingerOnceAndOneThatLocksTouchIDOutOnlyAsTheStoppedLine() async throws {
		let keys = FakeKeyStore()
		let spoken = Spoken()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys, spoken: spoken)
		defer { offscreen.close() }
		keys.reply(with: .miss)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { model.touchID == .paused(.shaking) && !spoken.heard.isEmpty }
		try await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && sensor.isWaiting }
		offscreen.pump(for: 0.05)
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement])

		keys.becomes(.lockedOut)
		sensor.touch()
		await offscreen.pump { model.touchID == .lockedOut && offscreen.glyphs.isEmpty }
		offscreen.pump(for: 0.1)

		#expect(model.shake.count == 2)
		#expect(line(in: offscreen) == UnlockView.touchIDStoppedLine)
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement, UnlockView.touchIDStoppedLine])
	}

	@Test func checkingAPasswordAfterTouchIDStopsKeepsAskingForThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		keys.reply(with: .cancel)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		sensor.touch()
		await offscreen.pump { model.touchID == .needsClick(after: .cancel) && offscreen.glyphs.isEmpty }
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)

		try offscreen.type("a guess", into: "Password").currentEditor()?.insertNewline(nil)
		await offscreen.pump { !offscreen.views(of: NSProgressIndicator.self).isEmpty }
		var lines: [String?] = []
		for _ in 0 ..< 20 {
			offscreen.pump()
			lines.append(line(in: offscreen))
		}
		gate.open()
		try await holding.value
		await offscreen.pump(turns: 4_000) { model.failure == .wrongPassword && offscreen.views(of: NSProgressIndicator.self).isEmpty }

		#expect(lines.count == 20)
		#expect(lines.allSatisfy { $0 == UnlockView.touchIDStoppedLine })
		#expect(model.failure == .wrongPassword)
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(line(in: offscreen) == UnlockView.touchIDStoppedLine)
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
		try await ring(shaking)
		await offscreen.pump { !model.shake.isRunning }
		offscreen.pump(for: 0.05)
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
	}

	@Test func typingWhileListeningKeepsTheSameAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let glyph = try #require(offscreen.glyphs.first)

		let field = try #require(offscreen.secureField("Password"))
		try #require(offscreen.window.makeFirstResponder(field))
		let editor = try #require(field.currentEditor())
		for letter in "correct horse" {
			editor.insertText(String(letter))
			offscreen.pump()
		}
		offscreen.pump(for: 0.1)

		#expect(offscreen.secureField("Password")?.stringValue == "correct horse")
		#expect(offscreen.glyphs.first === glyph)
		#expect(keys.contexts.count == 1)
		#expect(model.touchID == .listening(glyph.context))

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
	}

	@Test func aWrongPasswordShakesKeepsTheTextAndListensThroughAFreshGlyphOnlyOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let spoken = Spoken()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys, spoken: spoken)
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(offscreen.glyphs.first?.context)

		let field = try offscreen.type("a guess", into: "Password")
		let travel = Travel(of: field, in: offscreen)
		defer { travel.stop() }
		try #require(offscreen.accessibilityElements(.button).first { $0.label == UnlockView.arrowLabel }).press()
		await offscreen.pump(turns: 4_000) { model.failure == .wrongPassword && model.touchID == .paused(.shaking) }
		let offsets = await sideways(travel, in: offscreen, for: 0.6)

		#expect(offsets.contains { abs($0) > 0.5 })
		#expect(offsets.allSatisfy { abs($0) <= ShakeEffect.amplitude + 0.01 })
		#expect(offsets.last == 0)
		#expect(model.phase == .locked)
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: true))
		#expect(isInvalidated(first))
		#expect(offscreen.glyphs.isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(field.stringValue == "a guess")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 7, length: 0))
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		try await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && field.currentEditor()?.selectedRange.length == 7 }
		#expect(await shaking.requested == [.milliseconds(400)])

		#expect(field.stringValue == "a guess")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 7))
		#expect(offscreen.window.firstResponder === field.currentEditor())
		#expect(offscreen.glyphs.count == 1)
		#expect(offscreen.glyphs.first?.context === keys.contexts.last)
		#expect(offscreen.glyphs.first?.context !== first)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(!offscreen.accessibilityElements(.staticText).contains { $0.value.localizedCaseInsensitiveContains("wrong") })
		#expect(spoken.heard == [UnlockView.wrongPasswordAnnouncement])

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
	}

	@Test func aLockoutLeavesOnlyThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		keys.reply(with: .lockout)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { model.touchID == .lockedOut && offscreen.glyphs.isEmpty }

		#expect(model.touchID == .lockedOut)
		#expect(offscreen.glyphs.isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(offscreen.tryAgainButton == nil)
		#expect(offscreen.views(of: NSSecureTextField.self).first?.isEnabled == true)
		#expect(line(in: offscreen) == UnlockView.touchIDStoppedLine)
		#expect(model.shake.count == 0)
		let travel = Travel(of: try #require(offscreen.secureField("Password")), in: offscreen)
		defer { travel.stop() }
		#expect(await sideways(travel, in: offscreen, for: 0.3).allSatisfy { $0 == 0 })
		#expect(keys.contexts.count == 1)
	}

	@Test func whileTouchIDOpensTheNotesTheFormWaitsBehindASpinner() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library(holdingSearch: true).unlockedWithTouchID(keys)
		let offscreen = window(showing: model, watching: keys)
		defer { offscreen.close() }
		defer { opening.release() }
		await model.lock()
		model.search = "kayak"
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { opening.isHolding && offscreen.glyphs.isEmpty }

		let spinner = try #require(offscreen.views(of: NSProgressIndicator.self).first)
		let password = try #require(offscreen.secureField("Password"))
		#expect(model.touchID == .working)
		#expect(model.phase == .locked)
		#expect(offscreen.onScreen(spinner).minX > offscreen.onScreen(password).maxX)
		#expect(abs(offscreen.onScreen(spinner).midY - offscreen.onScreen(password).midY) < 1)
		#expect(offscreen.glyphs.isEmpty)
		#expect(!password.isEnabled)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		opening.release()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak"])
	}
}
