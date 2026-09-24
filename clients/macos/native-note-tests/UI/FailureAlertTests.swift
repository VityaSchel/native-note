import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct FailureAlertTests {
	@Test func unsavedEditsPutTheReasonLast() throws {
		let alert = try #require(AppModel.Failure.unsaved("disk I/O error").alert)

		#expect(alert.title == "Your latest edits could not be saved.")
		#expect(alert.message.hasPrefix("Native Note will keep trying"))
		#expect(alert.message.hasSuffix("disk I/O error"))
	}

	@Test func unexpectedFailuresShowTheirMessage() throws {
		let alert = try #require(AppModel.Failure.unexpected("The notes database is closed.").alert)

		#expect(alert.title == "Native Note could not continue.")
		#expect(alert.message == "The notes database is closed.")
	}

	@Test func aWrongPasswordShowsNoAlert() {
		#expect(AppModel.Failure.wrongPassword.alert == nil)
	}
}
