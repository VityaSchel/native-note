import AppKit
import Testing

@testable import NativeNote

@MainActor
struct UnlockViewTests {
	private func type(_ text: String, into field: NSTextField, of offscreen: OffscreenWindow<UnlockView>) throws {
		try #require(offscreen.window.makeFirstResponder(field))
		let editor = try #require(field.currentEditor())
		editor.insertText(text)
		offscreen.pump()
	}

	private func field(_ placeholder: String, in offscreen: OffscreenWindow<UnlockView>) throws -> NSSecureTextField {
		try #require(offscreen.views(of: NSSecureTextField.self).first { $0.placeholderString == placeholder })
	}

	@Test func submittingSendsThePasswordOnceAndClearsTheField() async throws {
		var submitted: [String] = []
		let offscreen = OffscreenWindow(UnlockView(isSetup: false, failure: nil, submit: { submitted.append($0) }, dismissFailure: {}))
		defer { offscreen.close() }
		let password = try field("Password", in: offscreen)

		try type("correct horse", into: password, of: offscreen)
		password.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !submitted.isEmpty && password.stringValue.isEmpty }

		#expect(submitted == ["correct horse"])
		#expect(password.stringValue.isEmpty)
	}

	@Test func settingUpWithMatchingPasswordsSubmitsOnce() async throws {
		var submitted: [String] = []
		let offscreen = OffscreenWindow(UnlockView(isSetup: true, failure: nil, submit: { submitted.append($0) }, dismissFailure: {}))
		defer { offscreen.close() }
		let password = try field("Password", in: offscreen)
		let confirmation = try field("Confirm password", in: offscreen)

		try type("correct horse", into: password, of: offscreen)
		try type("correct horse", into: confirmation, of: offscreen)
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !submitted.isEmpty }

		#expect(submitted == ["correct horse"])
	}

	@Test func settingUpWithMismatchedPasswordsSubmitsNothing() async throws {
		var submitted: [String] = []
		let offscreen = OffscreenWindow(UnlockView(isSetup: true, failure: nil, submit: { submitted.append($0) }, dismissFailure: {}))
		defer { offscreen.close() }
		let password = try field("Password", in: offscreen)
		let confirmation = try field("Confirm password", in: offscreen)

		try type("correct horse", into: password, of: offscreen)
		try type("correct hose", into: confirmation, of: offscreen)
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump(turns: 40) { !submitted.isEmpty }

		#expect(submitted.isEmpty)
		#expect(password.stringValue == "correct horse")
	}
}
