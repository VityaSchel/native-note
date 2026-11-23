import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.takesFocus)
struct UnlockViewTests {
	private func unlockView(
		_ state: AppModel.TouchID = .hidden,
		enabled: Bool = false,
		shake: AppModel.Shake = AppModel.Shake(),
		glyphs: Glyphs = Glyphs(),
		spoken: Spoken = Spoken(),
		submit: @escaping (String) async -> AppModel.Failure? = { _ in nil }
	) -> UnlockView {
		UnlockView(
			failure: nil,
			submit: submit,
			dismissFailure: {},
			touchID: TouchIDControls(state: state, isBiometricUnlockEnabled: enabled, listen: { glyphs.heard.append($0) }),
			shake: shake,
			eraseLibrary: {},
			announce: { spoken.heard.append($0) }
		)
	}

	private func shakingLockScreen(
		_ shaker: Shaker,
		spoken: Spoken = Spoken(),
		submit: @escaping (String) async -> AppModel.Failure? = { _ in nil }
	) -> OffscreenWindow<UnlockView> {
		let context = LAContext()
		let view = { unlockView(.listening(context), enabled: true, shake: shaker.shake, spoken: spoken, submit: submit) }
		let offscreen = OffscreenWindow(view())
		shaker.show = { [weak offscreen] in offscreen?.host.rootView = view() }
		return offscreen
	}

	private func selection(of field: NSTextField) -> NSRange? {
		field.currentEditor()?.selectedRange
	}

	private func lockScreen(
		_ state: AppModel.TouchID = .hidden,
		enabled: Bool = false,
		glyphs: Glyphs = Glyphs(),
		spoken: Spoken = Spoken(),
		submit: @escaping (String) async -> AppModel.Failure? = { _ in nil }
	) -> OffscreenWindow<UnlockView> {
		OffscreenWindow(unlockView(state, enabled: enabled, glyphs: glyphs, spoken: spoken, submit: submit))
	}

	private func centered(_ view: UnlockView) -> some View {
		view.frame(width: 720, height: 460)
	}

	private func isTyping(in offscreen: OffscreenWindow<some View>) throws -> Bool {
		let editor = try offscreen.field("Password").currentEditor()
		return editor != nil && offscreen.window.firstResponder === editor
	}

	private func pixels(in rect: NSRect, of rep: NSBitmapImageRep, in offscreen: OffscreenWindow<some View>) -> [NSColor?] {
		let step = offscreen.host.bounds.width / CGFloat(rep.pixelsWide)
		return stride(from: rect.minX + step / 2, to: rect.maxX, by: step).flatMap { x in
			stride(from: rect.minY + step / 2, to: rect.maxY, by: step).map { y in pixel(at: NSPoint(x: x, y: y), of: rep, in: offscreen) }
		}
	}

	private func paint(_ glyph: LAAuthenticationView) {
		let paint = Paint(frame: glyph.bounds)
		paint.autoresizingMask = [.width, .height]
		glyph.addSubview(paint)
	}

	private func arrows(in offscreen: OffscreenWindow<some View>) -> [AccessibilityElement] {
		offscreen.accessibilityElements(.button).filter { $0.label == UnlockView.arrowLabel }
	}

	private func snapshot(of offscreen: OffscreenWindow<some View>) throws -> NSBitmapImageRep {
		let rep = try #require(offscreen.host.bitmapImageRepForCachingDisplay(in: offscreen.host.bounds))
		offscreen.host.cacheDisplay(in: offscreen.host.bounds, to: rep)
		return rep
	}

	private func pixel(at point: NSPoint, of rep: NSBitmapImageRep, in offscreen: OffscreenWindow<some View>) -> NSColor? {
		let scale = CGFloat(rep.pixelsWide) / offscreen.host.bounds.width
		let top = offscreen.host.isFlipped ? point.y : offscreen.host.bounds.height - point.y
		return rep.colorAt(x: Int(point.x * scale), y: Int(top * scale))?.usingColorSpace(.sRGB)
	}

	private func inHost(_ view: NSView, of offscreen: OffscreenWindow<some View>) -> NSRect {
		offscreen.host.convert(view.bounds, from: view)
	}

	private func inHost(_ screen: NSRect, of offscreen: OffscreenWindow<some View>) -> NSRect {
		offscreen.host.convert(offscreen.window.convertFromScreen(screen), from: nil)
	}

	private func isOpaque(_ color: NSColor?, like expected: NSColor?) -> Bool {
		guard let color, let expected else { return false }
		return color.alphaComponent > 0.99
			&& abs(color.redComponent - expected.redComponent) < 0.03
			&& abs(color.greenComponent - expected.greenComponent) < 0.03
			&& abs(color.blueComponent - expected.blueComponent) < 0.03
	}

	@Test func returnSendsThePasswordOnceAndClearsTheField() async throws {
		var submitted: [String] = []
		let offscreen = lockScreen(submit: { submitted.append($0); return nil })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")

		try offscreen.type("correct horse", into: password)
		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !submitted.isEmpty && password.stringValue.isEmpty }

		#expect(submitted == ["correct horse"])
		#expect(password.stringValue.isEmpty)
	}

	@Test func theArrowSendsThePasswordOnceAndClearsTheField() async throws {
		var submitted: [String] = []
		let offscreen = lockScreen(submit: { submitted.append($0); return nil })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("correct horse", into: password)

		let arrow = try #require(arrows(in: offscreen).first)
		#expect(arrow.press())
		await offscreen.pump { !submitted.isEmpty && password.stringValue.isEmpty }

		#expect(submitted == ["correct horse"])
		#expect(password.stringValue.isEmpty)
	}

	@Test func theLockScreenIsOnePlainPasswordField() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		let password = try offscreen.field("Password")

		#expect(offscreen.views(of: NSSecureTextField.self).count == 1)
		#expect(password.font?.pointSize == 15)
		#expect(!password.isBezeled)
		#expect(!password.isBordered)
		#expect(!password.drawsBackground)
		#expect(password.isEnabled)
	}

	@Test func theFieldIsA36PointOpaqueCapsule() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		offscreen.pump(for: 0.1)
		let rep = try snapshot(of: offscreen)
		let password = inHost(try offscreen.field("Password"), of: offscreen)
		let column = password.maxX + 10
		let fill = try #require(pixel(at: NSPoint(x: column, y: password.midY), of: rep, in: offscreen))
		#expect(fill.alphaComponent > 0.99)

		var filled: CGFloat = 0
		for step in stride(from: -30, through: 30, by: 0.5) where isOpaque(pixel(at: NSPoint(x: column, y: password.midY + step), of: rep, in: offscreen), like: fill) {
			filled += 0.5
		}

		#expect(filled >= UnlockView.fieldHeight - 3)
		#expect(filled <= UnlockView.fieldHeight)
		#expect(!isOpaque(pixel(at: NSPoint(x: column, y: password.midY - UnlockView.fieldHeight), of: rep, in: offscreen), like: fill))
	}

	@Test func theArrowAppearsInsideTheFieldOnlyWhileItHasText() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		#expect(arrows(in: offscreen).isEmpty)

		try offscreen.type("c", into: password)

		let arrow = try #require(arrows(in: offscreen).first)
		let text = offscreen.onScreen(password)
		#expect(arrows(in: offscreen).count == 1)
		#expect(arrow.frame.width == UnlockView.arrowSide)
		#expect(arrow.frame.height == UnlockView.arrowSide)
		#expect(arrow.frame.minX > text.maxX)
		#expect(arrow.frame.maxX < offscreen.onScreen(offscreen.host).midX + 150)
		#expect(abs(arrow.frame.midY - text.midY) < 1)

		let editor = try #require(password.currentEditor())
		editor.selectAll(nil)
		editor.deleteBackward(nil)
		offscreen.pump()

		#expect(password.stringValue.isEmpty)
		#expect(arrows(in: offscreen).isEmpty)
	}

	@Test func theFieldIsARoundEndedCapsuleWithAHairlineEdge() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		offscreen.pump(for: 0.1)
		let rep = try snapshot(of: offscreen)
		let password = inHost(try offscreen.field("Password"), of: offscreen)
		let middle = offscreen.host.bounds.midX
		let radius = UnlockView.fieldHeight / 2
		let fill = try #require(pixel(at: NSPoint(x: password.maxX + 10, y: password.midY), of: rep, in: offscreen))
		func isFill(_ x: CGFloat, _ y: CGFloat) -> Bool {
			isOpaque(pixel(at: NSPoint(x: x, y: password.midY + y), of: rep, in: offscreen), like: fill)
		}

		for side: CGFloat in [-1, 1] {
			let end = middle + side * 150
			#expect(isFill(end - side * 2.5, 0))
			#expect(!isFill(end - side * 0.5, 0))
			#expect(!isFill(end + side * 0.5, 0))
			#expect(isFill(end - side * radius, radius - 3))
			#expect(isFill(end - side * radius, 3 - radius))
			#expect(!isFill(end - side * 3, radius - 3))
			#expect(!isFill(end - side * 3, 3 - radius))
			#expect(isFill(middle, side * (radius - 1.5)))
			#expect(!isFill(middle, side * (radius - 0.5)))
		}
	}

	@Test func theTextStartsFourteenPointsAndTheArrowEndsSevenPointsInsideTheCapsule() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		try offscreen.type("c", into: try offscreen.field("Password"))
		let middle = offscreen.onScreen(offscreen.host).midX
		let text = try #require(offscreen.accessibilityElements(.textField).first).frame
		let arrow = try #require(arrows(in: offscreen).first).frame

		#expect(abs(text.minX - (middle - 150) - 14) < 0.5)
		#expect(abs(middle + 150 - arrow.maxX - 7) < 0.5)
	}

	@Test func theArrowIsTheAccentColor() throws {
		let offscreen = lockScreen()
		defer { offscreen.close() }
		try offscreen.type("c", into: try offscreen.field("Password"))
		offscreen.pump(for: 0.1)
		let rep = try snapshot(of: offscreen)
		let arrow = inHost(try #require(arrows(in: offscreen).first).frame, of: offscreen)
		let tint = OffscreenWindow(Rectangle().fill(.tint).frame(width: 20, height: 20))
		defer { tint.close() }
		let accent = pixel(at: NSPoint(x: tint.host.bounds.midX, y: tint.host.bounds.midY), of: try snapshot(of: tint), in: tint)

		for x in [arrow.minX + 3, arrow.maxX - 3] {
			let drawn = pixel(at: NSPoint(x: x, y: arrow.midY), of: rep, in: offscreen)
			#expect(isOpaque(drawn, like: accent), "\(String(describing: drawn)) is not \(String(describing: accent))")
		}
	}

	@Test func unlockingHasOnlyTheArrowAndForgotPassword() throws {
		let unlock = lockScreen()
		defer { unlock.close() }
		try unlock.type("correct horse", into: try unlock.field("Password"))
		let unlockButtons = unlock.accessibilityElements(.button)

		#expect(unlockButtons.map(\.label) == [UnlockView.arrowLabel])
		#expect(unlockButtons.allSatisfy { $0.frame.width == UnlockView.arrowSide })
		#expect(unlock.accessibilityElements(.link).map(\.label) == ["Forgot Password?"])
		#expect(unlock.views(of: NSSecureTextField.self).map(\.placeholderString) == ["Password"])
	}

	@Test func eachTouchIDStateSaysWhetherTouchIDCanStillBeUsedOnTheLineUnderTheField() {
		let usable = "Touch ID or enter password"
		let stopped = "Enter password to enable Touch ID"
		let lines: [(AppModel.TouchID, String)] = [
			(.listening(LAContext()), usable),
			(.paused(.inBackground), usable),
			(.paused(.checkingPassword), usable),
			(.paused(.shaking), usable),
			(.working, usable),
			(.needsClick(after: .miss), stopped),
			(.needsClick(after: .cancel), stopped),
			(.needsClick(after: .failure), stopped),
			(.lockedOut, stopped),
		]

		for (state, line) in lines {
			let offscreen = lockScreen(state)
			defer { offscreen.close() }
			offscreen.pump(for: 0.05)

			#expect(UnlockView.line(for: state) == line, "\(state)")
			#expect(offscreen.staticTexts() == ["Native Note", line], "\(state)")
		}
		#expect(UnlockView.line(for: .hidden) == nil)
	}

	@Test func withTouchIDOffThereIsNoLineAndNothingListens() {
		let glyphs = Glyphs()
		let offscreen = lockScreen(.hidden, glyphs: glyphs)
		defer { offscreen.close() }
		offscreen.pump(for: 0.1)

		#expect(offscreen.staticTexts() == ["Native Note"])
		#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(offscreen.views(of: NSProgressIndicator.self).isEmpty)
		#expect(glyphs.heard.isEmpty)
	}

	@Test func theLineSitsUnderTheFieldAndForgotPasswordUnderTheLine() throws {
		func gaps(_ state: AppModel.TouchID) throws -> [CGFloat] {
			let offscreen = lockScreen(state)
			defer { offscreen.close() }
			offscreen.pump(for: 0.05)
			let text = offscreen.onScreen(try offscreen.field("Password"))
			let capsuleBottom = text.midY - UnlockView.fieldHeight / 2
			let forgot = try #require(offscreen.accessibilityElements(.link).first).frame
			guard let line = offscreen.accessibilityElements(.staticText).first(where: { $0.value == UnlockView.line(for: state) }) else {
				return [capsuleBottom - forgot.maxY]
			}
			return [capsuleBottom - line.frame.maxY, line.frame.minY - forgot.maxY]
		}

		let listening = try gaps(.listening(LAContext()))
		#expect(listening.count == 2)
		#expect(abs(listening[0] - 8) < 1)
		#expect(abs(listening[1] - 12) < 1)
		let off = try gaps(.hidden)
		#expect(off.count == 1)
		#expect(abs(off[0] - 12) < 1)
	}

	@Test func listeningPairsOneGlyphCoveredByTheField() async throws {
		let context = LAContext()
		let glyphs = Glyphs()
		let offscreen = lockScreen(.listening(context), glyphs: glyphs)
		defer { offscreen.close() }

		await offscreen.pump { !glyphs.heard.isEmpty }

		let glyph = try #require(offscreen.views(of: LAAuthenticationView.self).first)
		let password = try offscreen.field("Password")
		#expect(offscreen.views(of: LAAuthenticationView.self).count == 1)
		#expect(glyph.context === context)
		#expect(glyphs.heard.count == 1)
		#expect(glyphs.heard.first === glyph)
		#expect(glyph.window === offscreen.window)
		#expect(!glyph.isHiddenOrHasHiddenAncestor)
		#expect(sequence(first: glyph as NSView, next: \.superview).allSatisfy { $0.alphaValue == 1 && ($0.layer?.opacity ?? 1) == 1 })
		#expect(isBelow(glyph, password))

		let covered = offscreen.onScreen(glyph)
		let text = offscreen.onScreen(password)
		#expect(covered.size == NSSize(width: UnlockView.coveredGlyphSide, height: UnlockView.coveredGlyphSide))
		#expect(text.contains(covered))
		#expect(abs(covered.midX - offscreen.onScreen(offscreen.host).midX) < 0.5)
		#expect(abs(covered.midY - text.midY) < 0.5)
		#expect(offscreen.tryAgainButton == nil)
	}

	@Test func theFieldsOpaqueFillCoversTheGlyph() async throws {
		let glyphs = Glyphs()
		let offscreen = lockScreen(.listening(LAContext()), glyphs: glyphs)
		defer { offscreen.close() }
		await offscreen.pump { !glyphs.heard.isEmpty }
		let glyph = try #require(offscreen.views(of: LAAuthenticationView.self).first)
		paint(glyph)
		offscreen.pump()
		let rep = try snapshot(of: offscreen)
		let password = inHost(try offscreen.field("Password"), of: offscreen)
		let fill = try #require(pixel(at: NSPoint(x: password.maxX + 10, y: password.midY), of: rep, in: offscreen))
		let covered = pixels(in: inHost(glyph, of: offscreen), of: rep, in: offscreen)

		#expect(fill.alphaComponent > 0.99)
		#expect(!Paint.isPainted(fill))
		#expect(covered.count >= Int(UnlockView.coveredGlyphSide * UnlockView.coveredGlyphSide))
		#expect(covered.allSatisfy { isOpaque($0, like: fill) })

		let uncovered = OffscreenWindow(GlyphOverFill())
		defer { uncovered.close() }
		uncovered.pump(for: 0.05)
		let shown = try #require(uncovered.views(of: LAAuthenticationView.self).first)
		paint(shown)
		uncovered.pump()
		let drawn = pixels(in: inHost(shown, of: uncovered), of: try snapshot(of: uncovered), in: uncovered)
		#expect(drawn.count == covered.count)
		#expect(drawn.allSatisfy(Paint.isPainted))
	}

	@Test func voiceOverHearsTheFieldTheLineAndTheArrowButNotTheGlyph() async throws {
		let glyphs = Glyphs()
		let offscreen = lockScreen(.listening(LAContext()), glyphs: glyphs)
		defer { offscreen.close() }
		await offscreen.pump { !glyphs.heard.isEmpty }
		let glyph = try #require(offscreen.views(of: LAAuthenticationView.self).first)
		try offscreen.type("c", into: try offscreen.field("Password"))

		let elements = offscreen.accessibilityElements()
		let fields = elements.filter { $0.role == .textField }
		#expect(fields.map(\.placeholder) == ["Password"])
		#expect(elements.filter { $0.role == .staticText }.map(\.value) == ["Native Note", UnlockView.touchIDLine])
		#expect(elements.filter { $0.role == .button }.map(\.label) == [UnlockView.arrowLabel])
		#expect(!glyph.isAccessibilityElement())
		#expect(!elements.contains { $0.role == .image && $0.frame.intersects(offscreen.onScreen(glyph)) })
		#expect(!elements.contains { $0.label.localizedCaseInsensitiveContains("Touch ID") })
	}

	@Test func thePasswordFieldHasFocusWhenTheLockScreenAppears() async throws {
		for state in [AppModel.TouchID.hidden, .listening(LAContext()), .paused(.shaking), .needsClick(after: .cancel), .lockedOut] {
			let offscreen = lockScreen(state, enabled: state != .hidden)
			defer { offscreen.close() }
			try await offscreen.pump { try isTyping(in: offscreen) }

			#expect(try isTyping(in: offscreen), "\(state)")
		}
	}

	@Test func theFieldTakesFocusBackWhenTouchIDCannotOpenTheNotes() async throws {
		let offscreen = lockScreen(.listening(LAContext()), enabled: true)
		defer { offscreen.close() }
		try await offscreen.pump { try isTyping(in: offscreen) }
		try #require(try isTyping(in: offscreen))

		offscreen.host.rootView = unlockView(.working, enabled: true)
		try await offscreen.pump { try !offscreen.field("Password").isEnabled }
		#expect(!(try offscreen.field("Password").isEnabled))
		#expect(!(try isTyping(in: offscreen)))

		offscreen.host.rootView = unlockView(.needsClick(after: .failure), enabled: true)
		try await offscreen.pump { try isTyping(in: offscreen) }
		#expect(try offscreen.field("Password").isEnabled)
		#expect(try isTyping(in: offscreen))
	}

	@Test func theFormStaysPutWhileTouchIDComesAndGoesWithTouchIDUnlockOn() throws {
		let offscreen = OffscreenWindow(centered(unlockView(.listening(LAContext()), enabled: true)))
		defer { offscreen.close() }
		offscreen.pump(for: 0.05)
		let rest = offscreen.onScreen(try offscreen.field("Password"))
		let forgot = try #require(offscreen.accessibilityElements(.link).first).frame

		for state in [AppModel.TouchID.hidden, .paused(.shaking), .lockedOut, .hidden, .paused(.inBackground)] {
			offscreen.host.rootView = centered(unlockView(state, enabled: true))
			offscreen.pump(for: 0.05)

			#expect(offscreen.onScreen(try offscreen.field("Password")) == rest, "\(state)")
			#expect(offscreen.accessibilityElements(.link).first?.frame == forgot, "\(state)")
			#expect(offscreen.staticTexts() == ["Native Note"] + [UnlockView.line(for: state)].compactMap(\.self), "\(state)")
		}
	}

	@Test func withTouchIDUnlockOffTheFormKeepsNoRoomForALine() throws {
		func forgotBelowField(enabled: Bool) throws -> CGFloat {
			let offscreen = OffscreenWindow(centered(unlockView(.hidden, enabled: enabled)))
			defer { offscreen.close() }
			offscreen.pump(for: 0.05)
			let field = offscreen.onScreen(try offscreen.field("Password"))
			return field.midY - UnlockView.fieldHeight / 2 - (try #require(offscreen.accessibilityElements(.link).first).frame.maxY)
		}

		#expect(abs(try forgotBelowField(enabled: false) - 12) < 1)
		#expect(try forgotBelowField(enabled: true) > 30)
	}

	@Test func voiceOverHearsAWrongPasswordOnceAndNothingAfterOtherReplies() async throws {
		let replies: [(AppModel.Failure?, [String])] = [
			(.wrongPassword, ["Wrong password"]),
			(nil, []),
			(.unexpected("The notes database is closed."), []),
			(.unsaved("disk I/O error"), []),
		]
		for (reply, heard) in replies {
			let spoken = Spoken()
			let offscreen = lockScreen(.listening(LAContext()), enabled: true, spoken: spoken, submit: { _ in reply })
			defer { offscreen.close() }
			let password = try offscreen.field("Password")
			try offscreen.type("a guess", into: password)

			password.currentEditor()?.insertNewline(nil)
			await offscreen.pump { !spoken.heard.isEmpty || password.stringValue.isEmpty }
			offscreen.pump(for: 0.1)

			#expect(spoken.heard == heard, "\(String(describing: reply))")
		}
	}

	@Test func voiceOverHearsOnlyWhenTouchIDStopsOnTheScreen() {
		let spoken = Spoken()
		let offscreen = lockScreen(.listening(LAContext()), enabled: true, spoken: spoken)
		defer { offscreen.close() }
		offscreen.pump(for: 0.05)

		for state in [AppModel.TouchID.paused(.inBackground), .listening(LAContext()), .paused(.checkingPassword), .paused(.shaking), .listening(LAContext()), .needsClick(after: .cancel), .lockedOut, .listening(LAContext()), .hidden, .listening(LAContext())] {
			offscreen.host.rootView = unlockView(state, enabled: true, spoken: spoken)
			offscreen.pump(for: 0.05)
		}

		#expect(spoken.heard == [UnlockView.touchIDStoppedLine])

		let alreadyStopped = Spoken()
		let reopened = lockScreen(.lockedOut, enabled: true, spoken: alreadyStopped)
		defer { reopened.close() }
		reopened.pump(for: 0.05)
		#expect(alreadyStopped.heard.isEmpty)
	}

	@Test func voiceOverHearsAMissedTouchOnlyWhenTouchIDGoesStraightFromListeningToTheShake() {
		let spoken = Spoken()
		let offscreen = lockScreen(.listening(LAContext()), enabled: true, spoken: spoken)
		defer { offscreen.close() }
		offscreen.pump(for: 0.05)

		for state in [AppModel.TouchID.paused(.shaking), .listening(LAContext()), .paused(.checkingPassword), .paused(.shaking), .paused(.inBackground), .paused(.shaking), .listening(LAContext()), .lockedOut] {
			offscreen.host.rootView = unlockView(state, enabled: true, spoken: spoken)
			offscreen.pump(for: 0.05)
		}

		#expect(spoken.heard == ["Touch ID didn't match", "Enter password to enable Touch ID"])
		#expect(spoken.heard == [UnlockView.touchIDMissAnnouncement, UnlockView.touchIDStoppedLine])
	}

	@Test func typingKeepsListeningThroughTheSameGlyph() async throws {
		let context = LAContext()
		let glyphs = Glyphs()
		let offscreen = lockScreen(.listening(context), glyphs: glyphs)
		defer { offscreen.close() }
		await offscreen.pump { !glyphs.heard.isEmpty }
		let glyph = try #require(offscreen.views(of: LAAuthenticationView.self).first)
		let password = try offscreen.field("Password")

		try #require(offscreen.window.makeFirstResponder(password))
		let editor = try #require(password.currentEditor())
		for letter in "correct horse" {
			editor.insertText(String(letter))
			offscreen.pump()
		}
		offscreen.pump(for: 0.1)

		#expect(password.stringValue == "correct horse")
		#expect(offscreen.views(of: LAAuthenticationView.self).count == 1)
		#expect(offscreen.views(of: LAAuthenticationView.self).first === glyph)
		#expect(glyphs.heard.count == 1)
		#expect(!isInvalidated(context))
	}

	@Test func aWrongPasswordShakesTheFieldRowWithoutErrorText() async throws {
		let shaker = Shaker()
		var submitted: [String] = []
		let offscreen = shakingLockScreen(shaker, submit: { submitted.append($0); shaker.start(); return .wrongPassword })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		let travel = Travel(of: password, in: offscreen)
		defer { travel.stop() }

		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !travel.offsets.isEmpty }
		let started = Date()
		await offscreen.pump(turns: 8_000) { Date().timeIntervalSince(started) > 0.8 }

		#expect(submitted == ["a guess"])
		#expect(travel.offsets.contains { abs($0.dx) > 0.5 })
		#expect(travel.offsets.allSatisfy { abs($0.dx) <= ShakeEffect.amplitude + 0.01 })
		#expect(travel.offsets.allSatisfy { $0.dy == 0 })
		#expect(travel.offset().dx == 0)
		#expect(travel.offset().dy == 0)
		#expect(password.stringValue == "a guess")
		#expect(offscreen.staticTexts() == ["Native Note", UnlockView.touchIDLine])
	}

	@Test func eachRenderedFrameOfTheShakeMovesTheWholeFieldRowAlongTheCurveAndNothingElse() throws {
		let shaker = Shaker()
		let offscreen = shakingLockScreen(shaker)
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		offscreen.pump(for: 0.1)
		let still = offscreen.accessibilityElements().filter { $0.role == .staticText || $0.role == .link }.map(\.frame)
		let rest = offscreen.onScreen(password)
		let arrowRest = try #require(arrows(in: offscreen).first).frame
		let step = 1.0 / 120
		func moved() -> CGFloat { offscreen.onScreen(password).minX - rest.minX }

		shaker.start()
		var startup = 0
		while moved() == 0, startup < 10 {
			offscreen.host._renderForTest(interval: step)
			startup += 1
		}
		var offsets = [moved()]
		for _ in 0 ..< 60 {
			offscreen.host._renderForTest(interval: step)
			offsets.append(moved())
			if offsets.count == 4 {
				let arrow = try #require(arrows(in: offscreen).first).frame
				#expect(abs(arrow.minX - arrowRest.minX - offsets[3]) < 0.51)
				#expect(arrow.minY == arrowRest.minY)
				#expect(offscreen.accessibilityElements().filter { $0.role == .staticText || $0.role == .link }.map(\.frame) == still)
			}
		}

		#expect(startup < 10)
		for (index, offset) in offsets.enumerated() {
			#expect(abs(offset - ShakeEffect.offset(at: Double(index + 1) * step)) < 0.01, "frame \(index + 1)")
		}
		#expect(offsets[0] < 0)
		#expect(abs(offsets[3] + 14) < 0.01)
		#expect(abs(offsets[11] - 14) < 0.01)
		#expect(abs(offsets[27] - 8.78) < 0.01)
		#expect(offsets[47...].allSatisfy { $0 == 0 })
		#expect(offscreen.onScreen(password).minY == rest.minY)
	}

	@Test func aWrongPasswordKeepsTheTextAndSelectsAllOfItOnlyWhenTheShakeEnds() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let offscreen = shakingLockScreen(shaker, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)

		#expect(try #require(arrows(in: offscreen).first).press())
		await offscreen.pump { !spoken.heard.isEmpty }
		offscreen.pump(for: 0.2)

		#expect(password.stringValue == "a guess")
		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 7, length: 0))
		#expect(spoken.heard == [UnlockView.wrongPasswordAnnouncement])

		shaker.end()
		await offscreen.pump { selection(of: password)?.length == 7 }

		#expect(password.stringValue == "a guess")
		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
		#expect(arrows(in: offscreen).count == 1)
		try offscreen.type("correct horse", into: password)
		#expect(password.stringValue == "correct horse")
		#expect(spoken.heard == [UnlockView.wrongPasswordAnnouncement])
	}

	@Test func returnSelectsTheTextAsAppKitDoesAndItStaysSelectedThroughTheShake() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let offscreen = shakingLockScreen(shaker, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)

		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !spoken.heard.isEmpty }
		offscreen.pump(for: 0.2)

		#expect(password.stringValue == "a guess")
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
		shaker.end()
		offscreen.pump(for: 0.1)
		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
	}

	@Test func aWrongPasswordSelectsTheTextEvenIfTheFieldLostFocus() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let offscreen = shakingLockScreen(shaker, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !spoken.heard.isEmpty }
		offscreen.window.makeFirstResponder(nil)
		try await offscreen.pump { try !isTyping(in: offscreen) }
		try #require(try !isTyping(in: offscreen))

		shaker.end()
		try await offscreen.pump { try isTyping(in: offscreen) && selection(of: password)?.length == 7 }

		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
	}

	@Test func aWrongPasswordTakesFocusBackFromAnotherControlWhenTheShakeEnds() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let context = LAContext()
		var elsewhere = false
		let view = { BesideAnotherField(lock: unlockView(.listening(context), enabled: true, shake: shaker.shake, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword }), focused: elsewhere) }
		let offscreen = OffscreenWindow(view())
		shaker.show = { [weak offscreen] in offscreen?.host.rootView = view() }
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		let other = try #require(offscreen.views(of: NSTextField.self).first { $0.placeholderString == BesideAnotherField.placeholder })
		try offscreen.type("a guess", into: password)
		#expect(try #require(arrows(in: offscreen).first).press())
		await offscreen.pump { !spoken.heard.isEmpty }
		elsewhere = true
		offscreen.host.rootView = view()
		await offscreen.pump { other.currentEditor() != nil }
		offscreen.pump(for: 0.1)
		try #require(try !isTyping(in: offscreen))
		try #require(offscreen.window.firstResponder === other.currentEditor())

		shaker.end()
		try await offscreen.pump { try isTyping(in: offscreen) && selection(of: password)?.length == 7 }

		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
		#expect(password.stringValue == "a guess")
	}

	@Test func typingDuringTheShakeIsNotSelectedAwayWhenItEnds() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let offscreen = shakingLockScreen(shaker, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword })
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		#expect(try #require(arrows(in: offscreen).first).press())
		await offscreen.pump { !spoken.heard.isEmpty }

		try #require(password.currentEditor()).insertText("!")
		offscreen.pump()
		shaker.end()
		offscreen.pump(for: 0.2)

		#expect(password.stringValue == "a guess!")
		#expect(selection(of: password) == NSRange(location: 8, length: 0))
	}

	@Test func textTypedWhileThePasswordIsCheckedIsNotSelectedAwayWhenTheShakeEnds() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let checking = Latch()
		let offscreen = shakingLockScreen(shaker, spoken: spoken, submit: { _ in
			await checking.wait()
			shaker.start()
			return .wrongPassword
		})
		defer { offscreen.close() }
		defer { checking.release() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { checking.isHolding }

		try #require(password.currentEditor()).insertText("co")
		offscreen.pump()
		checking.release()
		await offscreen.pump { !spoken.heard.isEmpty }
		offscreen.pump(for: 0.1)
		shaker.end()
		offscreen.pump(for: 0.2)

		#expect(password.stringValue == "co")
		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 2, length: 0))
		#expect(spoken.heard == [UnlockView.wrongPasswordAnnouncement])
	}

	@Test func aShakeForAMissedTouchLeavesTheTypedTextAndFocusAlone() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let offscreen = shakingLockScreen(shaker, spoken: spoken)
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		try offscreen.type("corr", into: password)
		let travel = Travel(of: password, in: offscreen)
		defer { travel.stop() }

		shaker.start()
		await offscreen.pump { !travel.offsets.isEmpty }
		let started = Date()
		await offscreen.pump(turns: 8_000) { Date().timeIntervalSince(started) > 0.6 }
		shaker.end()
		offscreen.pump(for: 0.2)

		#expect(travel.offsets.contains { abs($0.dx) > 0.5 })
		#expect(travel.offsets.allSatisfy { abs($0.dx) <= ShakeEffect.amplitude + 0.01 && $0.dy == 0 })
		#expect(travel.offset().dx == 0)
		#expect(travel.offset().dy == 0)
		#expect(password.stringValue == "corr")
		#expect(try isTyping(in: offscreen))
		#expect(selection(of: password) == NSRange(location: 4, length: 0))
		#expect(spoken.heard.isEmpty)
		#expect(offscreen.staticTexts() == ["Native Note", UnlockView.touchIDLine])
	}

	@Test func withReduceMotionAWrongPasswordLeavesTheFieldStillAndStillSelectsItWhenTheShakeEnds() async throws {
		let shaker = Shaker()
		let spoken = Spoken()
		let view = {
			unlockView(shake: shaker.shake, spoken: spoken, submit: { _ in shaker.start(); return .wrongPassword })
				.environment(\._accessibilityReduceMotion, true)
		}
		let offscreen = OffscreenWindow(view())
		defer { offscreen.close() }
		shaker.show = { [weak offscreen] in offscreen?.host.rootView = view() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		let travel = Travel(of: password, in: offscreen)
		defer { travel.stop() }
		let field = inHost(password, of: offscreen)
		let fill = NSPoint(x: field.maxX - 8, y: field.midY)
		#expect(try offscreen.opacity(at: fill) > 0.99)

		#expect(try #require(arrows(in: offscreen).first).press())
		await offscreen.pump { shaker.shake.isRunning }
		let opacities = try offscreen.opacities(at: fill, steppingFrames: 72, every: 1.0 / 120)
		#expect(shaker.shake.count == 1)
		#expect(travel.offsets.allSatisfy { $0.dx == 0 && $0.dy == 0 })
		#expect(travel.offset().dx == 0 && travel.offset().dy == 0)
		#expect(try #require(opacities.min()) < 0.6)
		#expect(try #require(opacities.last) > 0.99)
		#expect(selection(of: password) == NSRange(location: 7, length: 0))
		#expect(spoken.heard == [UnlockView.wrongPasswordAnnouncement])

		shaker.end()
		await offscreen.pump { selection(of: password) == NSRange(location: 0, length: 7) }
		#expect(selection(of: password) == NSRange(location: 0, length: 7))
	}

	@Test func withReduceMotionEachRenderedFrameDimsTheWholeFieldRowInPlaceAlongTheCurve() throws {
		let shaker = Shaker()
		let view = {
			unlockView(shake: shaker.shake)
				.environment(\._accessibilityReduceMotion, true)
		}
		let offscreen = OffscreenWindow(view())
		defer { offscreen.close() }
		shaker.show = { [weak offscreen] in offscreen?.host.rootView = view() }
		let password = try offscreen.field("Password")
		try offscreen.type("a guess", into: password)
		offscreen.pump(for: 0.1)
		let still = offscreen.accessibilityElements().filter { $0.role == .staticText || $0.role == .link }.map(\.frame)
		let rest = offscreen.onScreen(password)
		let arrowRest = try #require(arrows(in: offscreen).first).frame
		let field = inHost(password, of: offscreen)
		let fill = NSPoint(x: field.maxX - 8, y: field.midY)
		let arrowFill = NSPoint(x: inHost(arrowRest, of: offscreen).midX, y: field.midY)
		let step = 1.0 / 120
		#expect(try offscreen.opacity(at: fill) > 0.99)

		shaker.start()
		var startup = 0
		while try offscreen.opacity(at: fill) > 0.99, startup < 10 {
			offscreen.host._renderForTest(interval: step)
			startup += 1
		}
		var opacities = [try offscreen.opacity(at: fill)]
		var arrowOpacities = [try offscreen.opacity(at: arrowFill)]
		for _ in 0 ..< 60 {
			offscreen.host._renderForTest(interval: step)
			opacities.append(try offscreen.opacity(at: fill))
			arrowOpacities.append(try offscreen.opacity(at: arrowFill))
			#expect(offscreen.onScreen(password) == rest)
			#expect(arrows(in: offscreen).first?.frame == arrowRest)
		}

		#expect(startup < 10)
		for (index, opacity) in opacities.enumerated() {
			#expect(abs(opacity - DimEffect.opacity(at: Double(index + 1) * step)) < 0.02, "frame \(index + 1)")
		}
		#expect(abs(opacities[23] - DimEffect.dimmest) < 0.02)
		#expect(opacities[47...].allSatisfy { $0 > 0.99 })
		#expect(arrowOpacities[23] < 0.7)
		#expect(arrowOpacities[47...].allSatisfy { $0 > 0.99 })
		#expect(offscreen.accessibilityElements().filter { $0.role == .staticText || $0.role == .link }.map(\.frame) == still)
	}

	@Test func aShakeCountThatDoesNotChangeDoesNotMoveTheField() async throws {
		let shaker = Shaker()
		shaker.shake = AppModel.Shake(count: 3, isRunning: true)
		let offscreen = shakingLockScreen(shaker)
		defer { offscreen.close() }
		let password = try offscreen.field("Password")
		let travel = Travel(of: password, in: offscreen)
		defer { travel.stop() }

		shaker.show()
		offscreen.pump(for: 0.2)
		shaker.end()
		offscreen.pump(for: 0.2)

		#expect(travel.offsets.allSatisfy { $0.dx == 0 && $0.dy == 0 })
	}

	@Test func successAndOtherFailuresClearTheFieldWithoutAShake() async throws {
		for reply in [AppModel.Failure?.none, .unexpected("The notes database is closed."), .unsaved("disk I/O error")] {
			let offscreen = lockScreen(submit: { _ in reply })
			defer { offscreen.close() }
			let password = try offscreen.field("Password")
			try offscreen.type("correct horse", into: password)
			let travel = Travel(of: password, in: offscreen)
			defer { travel.stop() }

			password.currentEditor()?.insertNewline(nil)
			await offscreen.pump { password.stringValue.isEmpty }
			let cleared = Date()
			await offscreen.pump(turns: 4_000) { Date().timeIntervalSince(cleared) > 0.6 }

			#expect(password.stringValue.isEmpty)
			#expect(travel.offsets.allSatisfy { $0.dx == 0 && $0.dy == 0 })
			#expect(travel.offset().dx == 0)
			#expect(travel.offset().dy == 0)
		}
	}

	@Test func theShakeFollowsTheMacLoginWindowCurve() {
		func x(_ milliseconds: Double) -> CGFloat {
			ShakeEffect.offset(at: milliseconds / 1000)
		}
		let measured: [(Double, CGFloat)] = [
			(5, -3.268235), (12.5, -7.777983), (20, -11.326238), (33.25, -13.999892), (50, -9.899495), (62.5, -2.731265), (80, 8.228994),
			(87.5, 11.640575), (110, 12.474091), (125, 5.357568), (140, -4.326238), (162.5, -13.730994), (185, -9.092273), (199.75, -0.164930),
			(200.25, 0.110500), (212.5, 5.085010), (225, 8.247282), (240, 8.238972), (262.5, 1.615694), (280, -4.700476), (290, -6.984223),
			(312.5, -6.230751), (330, -1.131947), (350, 4.915944), (362.5, 6.650258), (380, 5.296901), (395, 1.483271), (399.75, 0.074145),
		]

		#expect(ShakeEffect.duration == 0.4)
		#expect(ShakeEffect.amplitude == 14)
		for (milliseconds, offset) in measured {
			#expect(abs(x(milliseconds) - offset) < 1e-6, "\(milliseconds) ms")
		}
		#expect(x(0) == 0)
		#expect(x(400) == 0)
		#expect(x(401) == 0)
		#expect(x(-1) == 0)
		#expect(x(1) < 0)
		#expect(x(10) < 0)
		let peaks: [(Double, CGFloat)] = [(100.0 / 3, -14), (100, 14), (500.0 / 3, -14), (700.0 / 3, 8.78), (300, -7.68), (1100.0 / 3, 6.72)]
		for (milliseconds, peak) in peaks {
			#expect(abs(x(milliseconds) - peak) < 0.01, "\(milliseconds) ms")
			#expect(abs(x(milliseconds - 5)) < abs(peak))
			#expect(abs(x(milliseconds + 5)) < abs(peak))
		}
		let samples = stride(from: 0.0, through: 400, by: 0.25).map(x)
		#expect(samples.allSatisfy { abs($0) <= 14 + 1e-9 })
		#expect(zip(samples, samples.dropFirst()).count { $0 * $1 < 0 } == 5)
		#expect(zip(samples, samples.dropFirst()).allSatisfy { abs($0 - $1) < 0.17 })
	}

	@Test func theShakeEffectOnlyMovesSidewaysAndRestsOnWholeShakes() {
		let size = CGSize(width: 300, height: 36)
		for milliseconds in stride(from: 0.0, through: 400, by: 5) {
			let moved = ShakeEffect(animatableData: 6 + milliseconds / 400).effectValue(size: size)
			#expect(abs(moved.m31 - ShakeEffect.offset(at: milliseconds / 1000)) < 1e-9, "\(milliseconds) ms")
			#expect(moved.m32 == 0 && moved.m11 == 1 && moved.m12 == 0 && moved.m21 == 0 && moved.m22 == 1)
		}
		for count in 0 ... 3 {
			#expect(ShakeEffect(animatableData: CGFloat(count)).effectValue(size: size).m31 == 0)
		}
	}

	@Test func withReduceMotionTheRowDimsToThirtyFivePercentAndBackOverTheShakeInsteadOfMoving() {
		func opacity(_ milliseconds: Double) -> Double {
			DimEffect.opacity(at: milliseconds / 1000)
		}
		let samples = stride(from: 0.0, through: 400, by: 0.25).map(opacity)

		#expect(DimEffect.dimmest == 0.35)
		#expect(opacity(0) == 1)
		#expect(abs(opacity(200) - 0.35) < 1e-9)
		#expect(opacity(400) == 1)
		#expect(opacity(401) == 1)
		#expect(opacity(-1) == 1)
		#expect(opacity(1) < 1)
		#expect(samples.allSatisfy { $0 >= 0.35 - 1e-9 && $0 <= 1 })
		#expect(zip(samples[..<800], samples[1 ... 800]).allSatisfy { $0 >= $1 })
		#expect(zip(samples[800...], samples[801...]).allSatisfy { $0 <= $1 })
		let size = CGSize(width: 300, height: 36)
		for milliseconds in stride(from: 0.0, through: 400, by: 5) {
			#expect(ShakeEffect(animatableData: 6 + milliseconds / 400, moves: false).effectValue(size: size).isIdentity, "\(milliseconds) ms")
		}
	}

	@Test func whileTouchIDOpensTheNotesTheFieldIsDisabledWithASpinnerInTheArrowsPlaceAndUnlockReadsInProgress() throws {
		let offscreen = lockScreen(.working)
		defer { offscreen.close() }
		offscreen.pump(for: 0.1)

		let spinner = try #require(offscreen.views(of: NSProgressIndicator.self).first)
		let password = try offscreen.field("Password")
		let text = offscreen.onScreen(password)
		let slot = offscreen.onScreen(spinner)
		#expect(offscreen.views(of: NSProgressIndicator.self).count == 1)
		#expect(spinner.style == .spinning)
		#expect(spinner.controlSize == .small)
		#expect(slot.minX > text.maxX)
		#expect(abs(slot.midY - text.midY) < 1)
		#expect(slot.maxX < offscreen.onScreen(offscreen.host).midX + 150)
		#expect(!password.isEnabled)
		let unlock = try #require(arrows(in: offscreen).first)
		#expect(arrows(in: offscreen).count == 1)
		#expect(!unlock.isEnabled)
		#expect(unlock.value == OnboardingLabel.busyValue)
		#expect(unlock.frame.size == CGSize(width: UnlockView.arrowSide, height: UnlockView.arrowSide))
		#expect(abs(unlock.frame.midX - slot.midX) < 1 && abs(unlock.frame.midY - slot.midY) < 1)
		#expect(!offscreen.exposesASpinner)
		#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
		#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
		#expect(!(try #require(offscreen.accessibilityElements(.link).first).isEnabled))
	}

	@Test func whileThePasswordIsCheckedTheSpinnerTakesTheArrowsPlaceUnlockReadsInProgressAndTheFieldKeepsFocus() async throws {
		let checking = Latch()
		let offscreen = lockScreen(.paused(.checkingPassword), submit: { _ in
			await checking.wait()
			return nil
		})
		defer { offscreen.close() }
		defer { checking.release() }
		let password = try offscreen.field("Password")
		try offscreen.type("correct horse", into: password)
		let arrow = try #require(arrows(in: offscreen).first)
		#expect(arrow.isEnabled)
		#expect(arrow.value.isEmpty)

		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { checking.isHolding }
		offscreen.pump(for: 0.05)

		#expect(offscreen.views(of: NSProgressIndicator.self).count == 1)
		let unlock = try #require(arrows(in: offscreen).first)
		#expect(arrows(in: offscreen).count == 1)
		#expect(!unlock.isEnabled)
		#expect(unlock.value == OnboardingLabel.busyValue)
		#expect(unlock.frame == arrow.frame)
		#expect(!offscreen.exposesASpinner)
		#expect(password.isEnabled)
		#expect(password.currentEditor() != nil)
		#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)

		checking.release()
		await offscreen.pump { password.stringValue.isEmpty && offscreen.views(of: NSProgressIndicator.self).isEmpty }
		#expect(offscreen.views(of: NSProgressIndicator.self).isEmpty)
		#expect(arrows(in: offscreen).isEmpty)
	}

	@Test func afterTouchIDStopsOnlyThePasswordIsOffered() {
		for state in [AppModel.TouchID.needsClick(after: .miss), .needsClick(after: .cancel), .needsClick(after: .failure), .lockedOut] {
			let glyphs = Glyphs()
			let offscreen = lockScreen(state, glyphs: glyphs)
			defer { offscreen.close() }
			offscreen.pump(for: 0.1)

			#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
			#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
			#expect(offscreen.tryAgainButton == nil)
			#expect(offscreen.views(of: NSProgressIndicator.self).isEmpty)
			#expect(offscreen.views(of: NSSecureTextField.self).first?.isEnabled == true)
			#expect(offscreen.accessibilityElements(.button).isEmpty)
			#expect(glyphs.heard.isEmpty)
		}
	}

	@Test func whilePausedNothingListensAndNothingIsDrawnForTouchID() {
		for state in [AppModel.TouchID.paused(.inBackground), .paused(.checkingPassword), .paused(.shaking)] {
			let glyphs = Glyphs()
			let offscreen = lockScreen(state, glyphs: glyphs)
			defer { offscreen.close() }
			offscreen.pump(for: 0.1)

			#expect(offscreen.views(of: LAAuthenticationView.self).isEmpty)
			#expect(offscreen.views(of: TouchIDGlyphView.self).isEmpty)
			#expect(offscreen.tryAgainButton == nil)
			#expect(glyphs.heard.isEmpty)
		}
	}

	@Test func aGlyphThatLeavesTheWindowEndsItsAttempt() async throws {
		let context = LAContext()
		let glyphs = Glyphs()
		let offscreen = lockScreen(.listening(context), glyphs: glyphs)
		await offscreen.pump { !glyphs.heard.isEmpty }
		#expect(!isInvalidated(context))

		offscreen.close()

		#expect(isInvalidated(context))
	}
}

@MainActor
func isBelow(_ lower: NSView, _ upper: NSView) -> Bool {
	let upperChain = Array(sequence(first: upper, next: \.superview))
	var branch = lower
	while let parent = branch.superview {
		if let index = upperChain.firstIndex(of: parent) {
			guard index > 0, let lowerIndex = parent.subviews.firstIndex(of: branch), let upperIndex = parent.subviews.firstIndex(of: upperChain[index - 1]) else { return false }
			return lowerIndex < upperIndex
		}
		branch = parent
	}
	return false
}

@MainActor
private final class Glyphs {
	var heard: [LAAuthenticationView] = []
}

@MainActor
private final class Shaker {
	var shake = AppModel.Shake()
	var show: () -> Void = {}

	func start() {
		shake = AppModel.Shake(count: shake.count + 1, isRunning: true)
		show()
	}

	func end() {
		shake.isRunning = false
		show()
	}
}

private struct BesideAnotherField: View {
	static let placeholder = "Another field"

	let lock: UnlockView
	let focused: Bool
	@State private var other = ""
	@FocusState private var typingElsewhere: Bool

	var body: some View {
		VStack {
			lock
			TextField(Self.placeholder, text: $other)
				.focused($typingElsewhere)
		}
		.onChange(of: focused) { _, focused in
			typingElsewhere = focused
		}
	}
}

private final class Paint: NSView {
	static func isPainted(_ color: NSColor?) -> Bool {
		guard let color else { return false }
		return color.alphaComponent > 0.99 && color.redComponent > 0.8 && color.greenComponent < 0.5 && color.blueComponent > 0.8
	}

	override func draw(_ dirtyRect: NSRect) {
		NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
		bounds.fill()
	}
}

private struct GlyphOverFill: View {
	var body: some View {
		ZStack {
			Capsule().fill(Color(nsColor: .textBackgroundColor))
			TouchIDGlyph(mode: .listening(LAContext(), label: nil), size: .mini)
				.frame(width: UnlockView.coveredGlyphSide, height: UnlockView.coveredGlyphSide)
		}
		.frame(width: 300, height: UnlockView.fieldHeight)
	}
}
