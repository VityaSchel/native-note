import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct ChangePasswordFormTests {
	private func filled(current: String = "old password", password: String = "new password", confirmation: String = "new password") -> ChangePasswordForm {
		var form = ChangePasswordForm()
		form.current = current
		form.password = password
		form.confirmation = confirmation
		return form
	}

	@Test func matchingPasswordsSubmitOnce() {
		var form = filled()

		let first = form.submit()
		let second = form.submit()

		#expect(first?.current == "old password")
		#expect(first?.new == "new password")
		#expect(second == nil)
		#expect(form.working)
	}

	@Test func everyPasswordIsNeeded() {
		#expect(!filled(current: "").canSubmit)
		#expect(!filled(password: "").canSubmit)
		#expect(filled().canSubmit)
	}

	@Test func mismatchedNewPasswordsSaySoUntilEdited() {
		var form = filled(confirmation: "new pasword")

		#expect(form.submit() == nil)
		#expect(form.inlineMessage == "The new passwords do not match.")
		#expect(!form.working)

		form.confirmation = "new password"
		#expect(form.inlineMessage == nil)
	}

	@Test func aWrongCurrentPasswordClearsItAndSaysSoUntilRetyped() {
		var form = filled()
		_ = form.submit()

		form.finish(.wrongPassword)

		#expect(form.current.isEmpty)
		#expect(form.password == "new password")
		#expect(form.inlineMessage == "Wrong current password.")
		#expect(!form.working)
		form.current = "old password"
		#expect(form.inlineMessage == nil)
	}

	@Test func anUnexpectedFailureShowsItsReasonAndKeepsTheFields() {
		var form = filled()
		_ = form.submit()

		form.finish(.unexpected("Password not changed. Try again."))

		#expect(form.inlineMessage == "Password not changed. Try again.")
		#expect(form.current == "old password")
		#expect(form.canSubmit)
	}
}
