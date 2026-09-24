import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct AppModelFailureTests {
	@Test(arguments: [
		(Unlock.Failure.neverSetUp as any Error, "No unlock parameters were found beside the notes database."),
		(SQLiteError.checkpointBlocked, "The notes database is busy. Try again."),
		(SQLiteError.closed, "The notes database is closed."),
		(SQLiteError.newerSchema(found: 2, known: 1), "The notes database was written by a newer version of Native Note. Update the app to open it."),
		(SQLiteError.cannotOpen(code: 14, message: "unable to open database file"), "The notes database could not be opened. unable to open database file"),
		(SQLiteError.cannotExecute(code: 5, message: "database is locked", sql: "UPDATE note SET body = 'secret'"), "database is locked"),
		(SQLiteError.keyMustBe32Bytes(count: 16), "The unlock key was 16 bytes rather than 32."),
	])
	func everyStorageAndUnlockErrorReadsAsASentence(error: any Error, reason: String) {
		#expect(AppModel.Failure.reason(for: error) == reason)
		#expect(AppModel.Failure(error) == .unexpected(reason))
	}

	@Test func aWrongKeyIsAWrongPassword() {
		#expect(AppModel.Failure(Unlock.Failure.wrongPassword) == .wrongPassword)
		#expect(AppModel.Failure(SQLiteError.wrongKey) == .wrongPassword)
	}
}
