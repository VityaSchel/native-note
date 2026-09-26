import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct TurnOnTouchIDFormTests {
	private func filled(_ password: String = "correct horse") -> TurnOnTouchIDForm {
		var form = TurnOnTouchIDForm()
		form.password = password
		return form
	}

	@Test func thePasswordIsSubmittedOnce() {
		var form = filled()

		let first = form.submit()
		let second = form.submit()

		#expect(first == "correct horse")
		#expect(second == nil)
		#expect(form.working)
		#expect(!form.canSubmit)
	}

	@Test func thePasswordIsNeeded() {
		var form = filled("")

		#expect(!form.canSubmit)
		#expect(form.submit() == nil)
		#expect(!form.working)
	}

	@Test func aWrongPasswordClearsItAndSaysSoUntilRetyped() {
		var form = filled()
		_ = form.submit()

		form.finish(.wrongPassword)

		#expect(form.password.isEmpty)
		#expect(form.inlineMessage == "Wrong password.")
		#expect(!form.working)
		form.password = "correct horse"
		#expect(form.inlineMessage == nil)
		#expect(form.canSubmit)
	}

	@Test func aKeychainFailureShowsItsReasonAndKeepsThePassword() {
		var form = filled()
		_ = form.submit()

		form.finish(.unexpected("Touch ID unlock could not be turned on. Try again."))

		#expect(form.inlineMessage == "Touch ID unlock could not be turned on. Try again.")
		#expect(form.password == "correct horse")
		#expect(form.canSubmit)
		form.password = "correct horses"
		#expect(form.inlineMessage == "Touch ID unlock could not be turned on. Try again.")
	}

	@Test func submittingAgainClearsTheLastMessage() {
		var form = filled()
		_ = form.submit()
		form.finish(.unexpected("Touch ID is not available on this Mac."))

		_ = form.submit()

		#expect(form.inlineMessage == nil)
	}

	@Test func turningOnSaysNothing() {
		var form = filled()
		_ = form.submit()

		form.finish(nil)

		#expect(form.inlineMessage == nil)
		#expect(!form.working)
	}
}
