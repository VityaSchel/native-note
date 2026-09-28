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
		#expect(form.inlineMessage == "The passwords do not match.")
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

		form.finish(nil)

		#expect(form.password.isEmpty)
		#expect(form.confirmation.isEmpty)
		#expect(!form.working)
		form.password = "again"
		#expect(form.canSubmit)
	}

	@Test func nothingButAMismatchShowsInline() {
		var form = UnlockForm()
		#expect(form.inlineMessage == nil)

		form.password = "a"
		_ = form.submit(confirming: false)
		form.finish(.wrongPassword)

		#expect(form.inlineMessage == nil)
	}

	@Test func aWrongPasswordKeepsTheTextToBeSelected() {
		var form = UnlockForm()

		for _ in 0 ..< 2 {
			form.password = "a guess"
			_ = form.submit(confirming: false)
			form.finish(.wrongPassword)

			#expect(form.password == "a guess")
			#expect(form.rejected)
			#expect(!form.working)
			#expect(form.canSubmit)
			let first = form.takeRejection()
			let second = form.takeRejection()
			#expect(first)
			#expect(!second)
			#expect(!form.rejected)
		}
	}

	@Test func editingARejectedPasswordDropsTheSelection() {
		var form = UnlockForm()
		form.password = "a guess"
		_ = form.submit(confirming: false)
		form.finish(.wrongPassword)

		form.password = "a guess"
		#expect(form.rejected)
		form.password = "a guess!"

		#expect(!form.rejected)
		let taken = form.takeRejection()
		#expect(!taken)
	}

	@Test func textTypedWhileThePasswordIsCheckedIsNotTheRejectedPassword() {
		var form = UnlockForm()
		form.password = "a guess"
		_ = form.submit(confirming: false)

		form.password = "co"
		form.finish(.wrongPassword)

		#expect(form.password == "co")
		#expect(!form.rejected)
		let taken = form.takeRejection()
		#expect(!taken)

		_ = form.submit(confirming: false)
		form.finish(.wrongPassword)
		#expect(form.password == "co")
		#expect(form.rejected)
	}

	@Test func successAndOtherFailuresClearTheField() {
		var form = UnlockForm()

		for reply in [AppModel.Failure?.none, .unexpected("The notes database is closed."), .unsaved("disk I/O error"), .wrongExportPassphrase] {
			form.password = "correct horse"
			_ = form.submit(confirming: false)
			form.finish(reply)

			#expect(form.password.isEmpty)
			#expect(!form.rejected)
		}
	}
}
