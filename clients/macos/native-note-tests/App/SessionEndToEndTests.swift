import AppKit
import Foundation
import LocalAuthenticationEmbeddedUI
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(5)))
struct SessionEndToEndTests {
	private let password = "correct horse battery"
	private let typed = [
		"Trip to Lisbon\nferry at 07:20, pastéis de nata",
		"買い物リスト\n牛乳\nパン",
		"🎉 Party 👨‍👩‍👧‍👦\r\nbring the kettle",
	]

	private func field(_ placeholder: String, in window: OffscreenWindow<some View>) throws -> NSSecureTextField {
		try #require(window.views(of: NSSecureTextField.self).first { $0.placeholderString == placeholder })
	}

	private func type(_ text: String, into field: NSTextField, of window: OffscreenWindow<some View>) throws {
		try #require(window.window.makeFirstResponder(field))
		let editor = try #require(field.currentEditor())
		editor.insertText(text)
		window.pump()
	}

	private func submit(_ password: String, in window: OffscreenWindow<ContentView>, confirming: Bool) throws {
		let first = try field("Password", in: window)
		try type(password, into: first, of: window)
		if confirming {
			try type(password, into: try field("Confirm Password", in: window), of: window)
		}
		first.currentEditor()?.insertNewline(nil) ?? window.window.firstResponder?.insertNewline(nil)
	}

	private func editor(in window: OffscreenWindow<ContentView>) -> NSTextView? {
		window.views(of: NSTextView.self).first { !$0.isFieldEditor && $0.isEditable }
	}

	@Test func aWholeSessionThroughTheViews() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory)
		let exchange = LibraryExchange(model: model)
		let window = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560)
		defer { window.close() }

		await window.pump { model.phase == .needsSetup }
		try submit(password, in: window, confirming: true)
		await window.pump(turns: 20_000) { model.phase == .unlocked }
		try #require(model.phase == .unlocked, "\(String(describing: model.failure))")

		for text in typed {
			await model.createNote()
			await window.pump { editor(in: window)?.string == "" }
			let shown = try #require(editor(in: window))
			shown.insertText(text, replacementRange: NSRange(location: 0, length: 0))
			await window.pump { model.selectedNote?.body == text }
		}
		#expect(Set(model.notes.map(\.body)) == Set(typed))

		model.search = "Lisbon"
		await window.pump { model.groups.flatMap(\.notes).count == 1 }
		#expect(model.groups.flatMap(\.notes).map(\.title) == ["Trip to Lisbon"])
		model.search = ""
		await window.pump { model.groups.flatMap(\.notes).count == 3 }

		await model.lock()
		await window.pump { (try? field("Password", in: window)) != nil }
		try submit(password, in: window, confirming: false)
		await window.pump(turns: 20_000) { model.phase == .unlocked }
		#expect(Set(model.notes.map(\.body)) == Set(typed))

		let file = directory.appending(path: "Native Note.nnexport")
		#expect(await model.exportLibrary(to: file, passphrase: "session passphrase"))
		await exchange.receive(file)
		#expect(exchange.sheet == .passphrase)
		await exchange.importPending(passphrase: "session passphrase")
		#expect(exchange.lastImport == ImportSummary(skipped: 3))
		#expect(exchange.showsSummary)

		let saved = Set(model.notes.map(\.body))
		window.close()
		await settle { await model.flushPendingSaves() }
		let relaunched = AppModel(directory: directory)
		relaunched.start()
		await relaunched.submit(password: password)
		#expect(Set(relaunched.notes.map(\.body)) == saved)
	}

	@Test func changingThePasswordThroughItsForm() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory)
		model.start()
		await model.submit(password: password)
		try #require(model.phase == .unlocked, "\(String(describing: model.failure))")
		for text in typed {
			await model.createNote()
			model.edit(try #require(model.selection), text)
		}
		var closed = false
		let form = OffscreenWindow(ChangePasswordView(turnsTouchIDOff: false, change: model.changePassword(from:to:)) { closed = true })
		defer { form.close() }

		try type(password, into: try field("Current password", in: form), of: form)
		try type("staple battery horse", into: try field("New password", in: form), of: form)
		let confirmation = try field("Confirm new password", in: form)
		try type("staple battery horse", into: confirmation, of: form)
		confirmation.currentEditor()?.insertNewline(nil)
		await form.pump(turns: 20_000) { closed }
		try #require(closed)
		await model.lock()

		let relaunched = AppModel(directory: directory)
		relaunched.start()
		await relaunched.submit(password: "staple battery horse")
		#expect(Set(relaunched.notes.map(\.body)) == Set(typed))
		await relaunched.lock()
		await relaunched.submit(password: password)
		#expect(relaunched.failure == .wrongPassword)
	}

	private func tryTouchIDAgain(in window: OffscreenWindow<some View>) -> NSButton? {
		(window.views(of: NSButton.self) + window.sheetViews(of: NSButton.self)).first { $0.title == TryTouchIDAgainButton.title }
	}

	@Test func touchIDThroughTheViewsFromTurningItOnToARelaunch() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let keys = FakeKeyStore()
		let sensor = Sensor()
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		model.appBecameActive()
		let library = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 640)
		defer { library.close() }
		let settings = OffscreenWindow(SettingsView(model: model), width: 440, height: 300, catchesSheets: true)
		defer { settings.close() }
		sensor.watch(keys, in: library.window, settings.window)

		await library.pump { model.phase == .needsSetup }
		try submit(password, in: library, confirming: true)
		await library.pump(turns: 20_000) { model.phase == .unlocked }
		try #require(model.phase == .unlocked, "\(String(describing: model.failure))")
		for text in typed {
			await model.createNote()
			model.edit(try #require(model.selection), text)
		}
		#expect(await model.flushPendingSaves())

		await settings.pump { !settings.views(of: NSSwitch.self).isEmpty }
		let toggle = try #require(settings.views(of: NSSwitch.self).first)
		toggle.performClick(nil)
		await settings.pump { settings.sheet != nil }
		let sheet = try #require(settings.sheet)
		let sheetField = try #require(settings.sheetViews(of: NSSecureTextField.self).first { $0.placeholderString == "Password" })
		try #require(sheet.makeFirstResponder(sheetField))
		try #require(sheetField.currentEditor()).insertText("staple battery horse")
		settings.pump()
		sheetField.currentEditor()?.insertNewline(nil)
		await settings.pump(turns: 20_000) { sheetField.stringValue.isEmpty }
		#expect(keys.storedKey == nil)
		#expect(keys.contexts.isEmpty)

		keys.reply(with: .miss)
		try #require(sheet.makeFirstResponder(sheetField))
		try #require(sheetField.currentEditor()).insertText(password)
		settings.pump()
		sheetField.currentEditor()?.insertNewline(nil)
		await settings.pump(turns: 20_000) { sensor.isWaiting }
		#expect(settings.sheetViews(of: LAAuthenticationView.self).first?.context === model.touchID.listeningContext)
		sensor.touch()
		await settings.pump { tryTouchIDAgain(in: settings) != nil }
		#expect(!model.isBiometricUnlockEnabled)
		keys.reply(with: .key)
		try #require(tryTouchIDAgain(in: settings)).performClick(nil)
		await settings.pump { sensor.isWaiting }
		sensor.touch()
		await settings.pump { settings.sheet == nil && toggle.state == .on }
		try #require(model.isBiometricUnlockEnabled)

		await model.lock()
		await library.pump { sensor.isWaiting }
		#expect(library.views(of: LAAuthenticationView.self).first?.context === model.touchID.listeningContext)
		sensor.touch()
		await library.pump { model.phase == .unlocked }
		#expect(Set(model.notes.map(\.body)) == Set(typed))

		await model.lock()
		await library.pump { sensor.isWaiting }
		model.appResignedActive()
		await library.pump { library.views(of: LAAuthenticationView.self).isEmpty }
		#expect(library.views(of: TouchIDGlyphView.self).isEmpty)
		sensor.touch()
		model.appBecameActive()
		await library.pump { sensor.isWaiting }
		sensor.touch()
		await library.pump { model.phase == .unlocked }
		#expect(model.phase == .unlocked)

		await model.lock()
		await library.pump { sensor.isWaiting }
		let listened = keys.contexts.count
		var listenedWhileShaking = false
		func watchTheShake(listenedBefore contexts: Int) {
			guard model.shake.isRunning else { return }
			let freshGlyph = library.views(of: LAAuthenticationView.self).contains { glyph in !keys.contexts.contains { $0 === glyph.context } }
			if freshGlyph || keys.contexts.count != contexts || model.touchID.listeningContext != nil { listenedWhileShaking = true }
		}
		let lockField = try field("Password", in: library)
		await library.pump { lockField.currentEditor() != nil }
		#expect(library.window.firstResponder === lockField.currentEditor())
		try type("staple battery horse", into: lockField, of: library)
		lockField.currentEditor()?.insertNewline(nil)
		await library.pump(turns: 20_000) {
			watchTheShake(listenedBefore: listened)
			return model.shake.count == 1 && keys.contexts.count == listened + 1 && lockField.currentEditor()?.selectedRange.length == 20
		}
		#expect(!listenedWhileShaking)
		#expect(model.failure == .wrongPassword)
		#expect(model.phase == .locked)
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: false))
		#expect(lockField.stringValue == "staple battery horse")
		#expect(library.window.firstResponder === lockField.currentEditor())
		#expect(library.views(of: LAAuthenticationView.self).first?.context === keys.contexts.last)
		keys.reply(with: .miss)
		sensor.touch()
		await library.pump(turns: 20_000) {
			watchTheShake(listenedBefore: listened + 1)
			return model.shake.count == 2 && keys.contexts.count == listened + 2 && sensor.isWaiting
		}
		#expect(!listenedWhileShaking)
		#expect(model.shake == AppModel.Shake(count: 2, isRunning: false))
		#expect(tryTouchIDAgain(in: library) == nil)
		#expect(library.accessibilityElements(.staticText).contains { $0.value == UnlockView.touchIDLine })
		#expect(library.views(of: LAAuthenticationView.self).first?.context === keys.contexts.last)
		#expect(library.accessibilityElements(.staticText).contains { $0.value == UnlockView.touchIDLine })
		#expect(lockField.currentEditor()?.selectedRange == NSRange(location: 0, length: 20))
		keys.reply(with: .key)
		try #require(lockField.currentEditor()).insertText(password)
		library.pump()
		#expect(lockField.stringValue == password)
		try #require(library.accessibilityElements(.button).first { $0.label == UnlockView.arrowLabel }).press()
		await library.pump(turns: 20_000) { model.phase == .unlocked }
		#expect(model.phase == .unlocked)
		#expect(keys.contexts.count == listened + 2)
		sensor.touch()
		await library.pump { !sensor.isWaiting }
		#expect(model.phase == .unlocked)
		#expect(model.failure == nil)

		library.close()
		settings.close()
		await model.close()
		let relaunched = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		let reopened = OffscreenWindow(ContentView(exchange: LibraryExchange(model: relaunched)), width: 980, height: 640)
		defer { reopened.close() }
		sensor.watch(keys, in: reopened.window)
		await reopened.pump { relaunched.phase == .locked }
		reopened.pump(for: 0.1)
		#expect(relaunched.touchID == .paused(.inBackground))
		#expect(reopened.views(of: LAAuthenticationView.self).isEmpty)

		relaunched.appBecameActive()
		await reopened.pump { sensor.isWaiting }
		sensor.touch()
		await reopened.pump { relaunched.phase == .unlocked }

		#expect(relaunched.phase == .unlocked, "\(String(describing: relaunched.failure))")
		#expect(Set(relaunched.notes.map(\.body)) == Set(typed))
		#expect(keys.reasons == ["turn on Touch ID unlock", "turn on Touch ID unlock"] + Array(repeating: "unlock your notes", count: 7))
		#expect(sensor.readsThroughAGlyphInTheWindow == Array(repeating: true, count: 9))
		#expect(keys.contexts.allSatisfy(isInvalidated))
	}
}
