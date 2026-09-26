import AppKit
import Foundation
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
			try type(password, into: try field("Confirm password", in: window), of: window)
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
		#expect(exchange.lastImport == ImportSummary(unchanged: 3))
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
}
