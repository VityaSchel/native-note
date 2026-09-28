import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LockScreenTouchIDTests {
	private let alarm = Alarm()
	private let shaking = Alarm()
	private let sensor = Sensor()
	private let opening = Latch()

	private func library(_ keys: FakeKeyStore, holdingSearch: Bool = false) async throws -> (AppModel, URL, OffscreenWindow<ContentView>) {
		let (model, directory) = try await unlockedModel { [alarm, shaking, opening] directory in
			AppModel(
				directory: directory,
				scheduler: SaveScheduler(sleep: alarm.sleep),
				searchNotes: { store, text in
					if holdingSearch { await opening.wait() }
					return try await store.search(text)
				},
				keyStore: keys,
				shakeTimer: shaking.sleep
			)
		}
		try await fill(model, with: ["kayak", "canoe"])
		try await turnOnTouchID(model)
		keys.forgetReads()
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 720, height: 640)
		sensor.watch(keys, in: offscreen.window)
		return (model, directory, offscreen)
	}

	private func glyphs(in offscreen: OffscreenWindow<ContentView>) -> [LAAuthenticationView] {
		offscreen.views(of: LAAuthenticationView.self)
	}

	private func tryAgainButton(in offscreen: OffscreenWindow<ContentView>) -> NSButton? {
		offscreen.views(of: NSButton.self).first { $0.title == TryTouchIDAgainButton.title }
	}

	private func passwordField(in offscreen: OffscreenWindow<ContentView>) -> NSSecureTextField? {
		offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == "Password" }
	}

	private func line(in offscreen: OffscreenWindow<ContentView>) -> String? {
		offscreen.accessibilityElements(.staticText).map(\.value).first { $0 == UnlockView.touchIDLine || $0 == UnlockView.touchIDStoppedLine }
	}

	private func sideways(_ travel: Travel<ContentView>, in offscreen: OffscreenWindow<ContentView>, for seconds: TimeInterval) async -> [CGFloat] {
		let started = Date()
		await offscreen.pump(turns: 8_000) { Date().timeIntervalSince(started) > seconds }
		#expect(travel.offsets.allSatisfy { $0.dy == 0 } && travel.offset().dy == 0)
		return travel.offsets.map(\.dx) + [travel.offset().dx]
	}

	private func type(_ text: String, in offscreen: OffscreenWindow<ContentView>) throws -> NSSecureTextField {
		let field = try #require(passwordField(in: offscreen))
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	@Test func lockingListensThroughAGlyphPairedWithTheModelsAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }

		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		let glyph = try #require(glyphs(in: offscreen).first)
		let password = try #require(passwordField(in: offscreen))
		#expect(glyphs(in: offscreen).count == 1)
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
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }

		#expect(model.phase == .unlocked)
		#expect(Set(model.notes.map(\.body)) == ["kayak", "canoe"])
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(keys.contexts.allSatisfy(isInvalidated))
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
	}

	@Test func anotherAppInFrontStopsListeningAndReturningListensThroughAFreshGlyph() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(glyphs(in: offscreen).first?.context)

		model.appResignedActive()
		await offscreen.pump { glyphs(in: offscreen).isEmpty }

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		model.appBecameActive()
		await offscreen.pump { keys.contexts.count == 2 }

		let second = try #require(glyphs(in: offscreen).first?.context)
		#expect(second !== first)
		#expect(keys.contexts.last === second)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
	}

	@Test func aWrongFingerShakesTheFieldAndAFreshGlyphListensOnlyOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		keys.reply(with: .miss)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(glyphs(in: offscreen).first?.context)
		let field = try type("corr", in: offscreen)
		let travel = Travel(of: field, in: offscreen)
		defer { travel.stop() }

		sensor.touch()
		await offscreen.pump { model.touchID == .paused(.shaking) && glyphs(in: offscreen).isEmpty }
		let offsets = await sideways(travel, in: offscreen, for: 0.6)

		#expect(offsets.contains { abs($0) > 0.5 })
		#expect(offsets.allSatisfy { abs($0) <= ShakeEffect.amplitude + 0.01 })
		#expect(offsets.last == 0)
		#expect(model.touchID == .paused(.shaking))
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(tryAgainButton(in: offscreen) == nil)
		#expect(keys.contexts.count == 1)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(model.failure == nil)

		await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && sensor.isWaiting }
		#expect(await shaking.requested == [.milliseconds(400)])

		let again = try #require(glyphs(in: offscreen).first?.context)
		#expect(again !== first)
		#expect(keys.contexts.last === again)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(field.stringValue == "corr")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 4, length: 0))
		keys.reply(with: .key)
		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
	}

	@Test func checkingAPasswordAfterTouchIDStopsKeepsAskingForThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		keys.reply(with: .cancel)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		sensor.touch()
		await offscreen.pump { model.touchID == .needsClick(after: .cancel) && glyphs(in: offscreen).isEmpty }
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)

		try type("a guess", in: offscreen).currentEditor()?.insertNewline(nil)
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
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(keys.contexts.count == 1)
		await ring(shaking)
		await offscreen.pump { !model.shake.isRunning }
		offscreen.pump(for: 0.05)
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(keys.contexts.count == 1)
	}

	@Test func typingWhileListeningKeepsTheSameAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let glyph = try #require(glyphs(in: offscreen).first)

		let field = try #require(passwordField(in: offscreen))
		try #require(offscreen.window.makeFirstResponder(field))
		let editor = try #require(field.currentEditor())
		for letter in "correct horse" {
			editor.insertText(String(letter))
			offscreen.pump()
		}
		offscreen.pump(for: 0.1)

		#expect(passwordField(in: offscreen)?.stringValue == "correct horse")
		#expect(glyphs(in: offscreen).first === glyph)
		#expect(keys.contexts.count == 1)
		#expect(model.touchID == .listening(glyph.context))

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
	}

	@Test func aWrongPasswordShakesKeepsTheTextAndListensThroughAFreshGlyphOnlyOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		await model.lock()
		await offscreen.pump { sensor.isWaiting }
		let first = try #require(glyphs(in: offscreen).first?.context)

		let field = try type("a guess", in: offscreen)
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
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(keys.contexts.count == 1)
		#expect(field.stringValue == "a guess")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 7, length: 0))
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		await ring(shaking)
		await offscreen.pump { keys.contexts.count == 2 && field.currentEditor()?.selectedRange.length == 7 }
		#expect(await shaking.requested == [.milliseconds(400)])

		#expect(field.stringValue == "a guess")
		#expect(field.currentEditor()?.selectedRange == NSRange(location: 0, length: 7))
		#expect(offscreen.window.firstResponder === field.currentEditor())
		#expect(glyphs(in: offscreen).count == 1)
		#expect(glyphs(in: offscreen).first?.context === keys.contexts.last)
		#expect(glyphs(in: offscreen).first?.context !== first)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)
		#expect(!offscreen.accessibilityElements(.staticText).contains { $0.value.localizedCaseInsensitiveContains("wrong") })

		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(sensor.readsThroughAGlyphInTheWindow == [true, true])
	}

	@Test func aLockoutLeavesOnlyThePassword() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		keys.reply(with: .lockout)
		await model.lock()
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { model.touchID == .lockedOut && glyphs(in: offscreen).isEmpty }

		#expect(model.touchID == .lockedOut)
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(tryAgainButton(in: offscreen) == nil)
		#expect(offscreen.views(of: NSSecureTextField.self).first?.isEnabled == true)
		#expect(line(in: offscreen) == UnlockView.touchIDStoppedLine)
		#expect(model.shake.count == 0)
		let travel = Travel(of: try #require(passwordField(in: offscreen)), in: offscreen)
		defer { travel.stop() }
		#expect(await sideways(travel, in: offscreen, for: 0.3).allSatisfy { $0 == 0 })
		#expect(keys.contexts.count == 1)
	}

	@Test func whileTouchIDOpensTheNotesTheFormWaitsBehindASpinner() async throws {
		let keys = FakeKeyStore()
		let (model, directory, offscreen) = try await library(keys, holdingSearch: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		defer { opening.release() }
		await model.lock()
		model.search = "kayak"
		await offscreen.pump { sensor.isWaiting }

		sensor.touch()
		await offscreen.pump { opening.isHolding && glyphs(in: offscreen).isEmpty }

		let spinner = try #require(offscreen.views(of: NSProgressIndicator.self).first)
		let password = try #require(passwordField(in: offscreen))
		#expect(model.touchID == .working)
		#expect(model.phase == .locked)
		#expect(offscreen.onScreen(spinner).minX > offscreen.onScreen(password).maxX)
		#expect(abs(offscreen.onScreen(spinner).midY - offscreen.onScreen(password).midY) < 1)
		#expect(glyphs(in: offscreen).isEmpty)
		#expect(!password.isEnabled)
		#expect(line(in: offscreen) == UnlockView.touchIDLine)

		opening.release()
		await offscreen.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak"])
	}
}
