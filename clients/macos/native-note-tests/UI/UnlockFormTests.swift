import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct UnlockFormTests {
	@Test func anEmptyPasswordIsNotSubmitted() {
		var form = UnlockForm()

		#expect(!form.canSubmit)
		#expect(form.submit(confirming: false) == nil)
		#expect(!form.working)
	}

	@Test func setupRefusesAConfirmationThatDoesNotMatch() {
		var form = UnlockForm()
		form.password = "correct horse"
		form.confirmation = "correct hose"

		#expect(form.submit(confirming: true) == nil)
		#expect(form.mismatched)
		#expect(form.inlineMessage(for: nil) == "The passwords do not match.")
		#expect(!form.working)
	}

	@Test func editingEitherFieldClearsTheMismatch() {
		var form = UnlockForm()
		form.password = "correct horse"
		form.confirmation = "correct hose"
		_ = form.submit(confirming: true)

		form.confirmation = "correct hose"
		#expect(form.mismatched)
		form.password = "correct horse"
		#expect(form.mismatched)

		form.confirmation = "correct horse"
		#expect(!form.mismatched)

		form.confirmation = "x"
		_ = form.submit(confirming: true)
		form.password = "y"
		#expect(!form.mismatched)
	}

	@Test func unlockIgnoresTheConfirmationField() {
		var form = UnlockForm()
		form.password = "correct horse"
		form.confirmation = "something else"

		#expect(form.submit(confirming: false) == "correct horse")
		#expect(!form.mismatched)
	}

	@Test func aSubmissionInFlightBlocksASecond() {
		var form = UnlockForm()
		form.password = "correct horse"

		#expect(form.submit(confirming: false) == "correct horse")
		#expect(form.working)
		#expect(!form.canSubmit)
		#expect(form.submit(confirming: false) == nil)
	}

	@Test func finishingClearsBothFieldsAndAllowsAnotherTry() {
		var form = UnlockForm()
		form.password = "correct horse"
		form.confirmation = "correct horse"
		_ = form.submit(confirming: true)

		form.finish()

		#expect(form.password.isEmpty)
		#expect(form.confirmation.isEmpty)
		#expect(!form.working)
		form.password = "again"
		#expect(form.canSubmit)
	}

	@Test func onlyAWrongPasswordShowsInline() {
		let form = UnlockForm()

		#expect(form.inlineMessage(for: .wrongPassword) == "Wrong password.")
		#expect(form.inlineMessage(for: .unsaved("disk I/O error")) == nil)
		#expect(form.inlineMessage(for: .unexpected("The notes database is closed.")) == nil)
		#expect(form.inlineMessage(for: nil) == nil)
	}

	@Test func aMismatchOutranksAWrongPassword() {
		var form = UnlockForm()
		form.password = "a"
		form.confirmation = "b"
		_ = form.submit(confirming: true)

		#expect(form.inlineMessage(for: .wrongPassword) == "The passwords do not match.")
	}
}
