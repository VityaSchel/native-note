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

	@Test func anUnconfirmedPassphraseIsNotAMismatchYet() {
		var form = ExportForm()
		form.passphrase = "correct staple"

		#expect(!form.mismatched)
		#expect(!form.canExport)
	}
}
