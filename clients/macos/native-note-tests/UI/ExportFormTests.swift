import AppKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct ExportFormTests {
	@Test func anEncryptedExportNeedsAMatchingPassphrase() {
		var form = ExportForm()
		#expect(form.encrypts)
		#expect(!form.canExport)

		form.passphrase = "correct staple"
		form.confirmation = "correct stapler"
		#expect(form.mismatched)
		#expect(!form.canExport)

		form.confirmation = "correct staple"
		#expect(!form.mismatched)
		#expect(form.canExport)
		#expect(form.passphraseToUse == "correct staple")
	}

	@Test func aPlainExportNeedsNoPassphrase() {
		var form = ExportForm()
		form.passphrase = "typed then switched off"

		form.encrypts = false

		#expect(form.canExport)
		#expect(!form.mismatched)
		#expect(form.passphraseToUse == nil)
	}

	@Test func aMismatchStopsMatteringWhenEncryptionIsOff() {
		var form = ExportForm()
		form.passphrase = "correct staple"
		form.confirmation = "correct stapler"

		form.encrypts = false

		#expect(!form.mismatched)
	}

	@Test func aConfirmationIsAMismatchOnlyOnceItLeavesThePassphrase() {
		var form = ExportForm()
		form.passphrase = "correct staple"

		form.confirmation = "corr"
		#expect(!form.mismatched)
		#expect(!form.canExport)

		form.confirmation = "corx"
		#expect(form.mismatched)
		#expect(!form.canExport)
	}

	@Test func submittingAConfirmationThatOnlyStartsThePassphraseIsAMismatchUntilEitherChanges() {
		var form = ExportForm()
		form.passphrase = "correct staple"
		form.confirmation = "corr"

		let early = form.submit()
		#expect(!early)
		#expect(form.mismatched)

		form.confirmation = "corre"
		#expect(!form.mismatched)
		let stillEarly = form.submit()
		#expect(!stillEarly)
		#expect(form.mismatched)

		form.passphrase = "corre"
		#expect(!form.mismatched)
		let matching = form.submit()
		#expect(matching)
		#expect(!form.mismatched)
		#expect(form.passphraseToUse == "corre")
	}

	@Test func anUnconfirmedPassphraseIsNotAMismatchYet() {
		var form = ExportForm()
		form.passphrase = "correct staple"

		#expect(!form.mismatched)
		#expect(!form.canExport)
	}
}

@MainActor @Suite(.takesFocus)
struct ExportSheetTests {
	@Test func typingTheVerifyFieldReadsOutAMismatchOnlyOnceItLeavesThePassphrase() throws {
		let spoken = Spoken()
		let offscreen = OffscreenWindow(ExportSheet(export: { _ in }, cancel: {}, announce: { spoken.hear($0) }), width: 400, height: 260)
		defer { offscreen.close() }
		let fields = offscreen.views(of: NSSecureTextField.self).sorted { offscreen.onScreen($0).maxY > offscreen.onScreen($1).maxY }
		try #require(fields.count == 2)
		try offscreen.type("correct staple", into: fields[0])
		try offscreen.type("", into: fields[1])
		let verify = try #require(fields[1].currentEditor())

		for typed in "correct staple" {
			verify.insertText(String(typed))
			offscreen.pump()
			#expect(spoken.heard.isEmpty, "\(fields[1].stringValue)")
		}
		#expect(!offscreen.texts().contains("The passphrases do not match."))

		verify.insertText("r")
		offscreen.pump()

		#expect(offscreen.texts().contains("The passphrases do not match."))
		#expect(spoken.heard == ["The passphrases do not match."])
		#expect(spoken.lines.map(\.accessibilitySpeechAnnouncementPriority) == [.high])
	}

	@Test func returnInTheVerifyFieldBeforeItHoldsTheWholePassphraseReadsOutTheMismatchAndExportsNothing() throws {
		let spoken = Spoken()
		var exported: [String?] = []
		let offscreen = OffscreenWindow(ExportSheet(export: { exported.append($0) }, cancel: {}, announce: { spoken.hear($0) }), width: 400, height: 260)
		defer { offscreen.close() }
		let fields = offscreen.views(of: NSSecureTextField.self).sorted { offscreen.onScreen($0).maxY > offscreen.onScreen($1).maxY }
		try #require(fields.count == 2)
		try offscreen.type("correct staple", into: fields[0])
		try offscreen.type("corr", into: fields[1])
		#expect(spoken.heard.isEmpty)

		try #require(fields[1].currentEditor()).insertNewline(nil)
		offscreen.pump()

		#expect(exported.isEmpty)
		#expect(offscreen.texts().contains("The passphrases do not match."))
		#expect(spoken.heard == ["The passphrases do not match."])

		if fields[1].currentEditor() == nil { try #require(offscreen.window.makeFirstResponder(fields[1])) }
		let verify = try #require(fields[1].currentEditor())
		verify.selectAll(nil)
		verify.insertText("correct staple")
		offscreen.pump()
		#expect(!offscreen.texts().contains("The passphrases do not match."))
		verify.insertNewline(nil)
		offscreen.pump()

		#expect(exported == ["correct staple"])
		#expect(spoken.heard == ["The passphrases do not match."])
	}
}
