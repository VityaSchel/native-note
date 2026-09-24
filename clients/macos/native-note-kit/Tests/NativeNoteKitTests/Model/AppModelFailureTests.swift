import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct AppModelFailureTests {
	@Test(arguments: [
		(Unlock.Failure.neverSetUp as any Error, "No unlock parameters were found beside the notes database."),
		(Unlock.Failure.alreadySetUp, "Native Note is already set up."),
		(Unlock.Failure.databaseMissing, "The notes database is missing."),
		(Unlock.Failure.boundToAnotherMac, "These notes are bound to another Mac's Secure Enclave and cannot open here. Restore them from an export."),
		(Unlock.Failure.passwordNotChanged, "Password not changed. Try again."),
		(AppLock.Unreadable.unsupportedVersion(2), "The unlock parameters were written by a newer version of Native Note. Update the app to open them."),
		(SQLiteError.closed, "The notes database is closed."),
		(SQLiteError.newerSchema(found: 2, known: 1), "The notes database was written by a newer version of Native Note. Update the app to open it."),
		(SQLiteError.cannotOpen(code: 14, message: "unable to open database file"), "The notes database could not be opened. unable to open database file"),
		(SQLiteError.cannotExecute(code: 5, message: "database is locked", sql: "UPDATE note SET body = 'secret'"), "database is locked"),
		(SQLiteError.keyMustBe32Bytes(count: 16), "The unlock key was 16 bytes rather than 32."),
		(ExportEnvelope.Failure.parametersOutOfBounds, "The export asks for more memory or time than Native Note allows."),
		(ExportEnvelope.Failure.notAnExport, "This file is not a Native Note export, or it is damaged."),
		(ZipArchive.Failure.notAZip, "This file is not a Native Note export, or it is damaged."),
		(NoteMarkdown.Failure.noFrontMatter, "This file is not a Native Note export, or it is damaged."),
		(LibraryArchive.Failure.notText("a.md"), "This file is not a Native Note export, or it is damaged."),
		(LibraryArchive.Failure.tooLarge, "The file is too large to be a Native Note export."),
		(ZipArchive.Failure.tooLarge, "The library is too large to export as one zip."),
		(CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: "/tmp/gone.zip"]), "The file “gone.zip” couldn’t be opened because there is no such file."),
	])
	func everyStorageAndUnlockErrorReadsAsASentence(error: any Error, reason: String) {
		#expect(AppModel.Failure.reason(for: error) == reason)
		#expect(AppModel.Failure(error) == .unexpected(reason))
	}

	@Test func anyOtherErrorReadsAsItsDescription() {
		let error = Argon2.Failure.rejected(code: -22, message: "Memory allocation error")

		#expect(AppModel.Failure(error) == .unexpected(String(describing: error)))
	}

	@Test func aRefusedExportPassphraseIsItsOwnFailure() {
		#expect(AppModel.Failure(ExportEnvelope.Failure.wrongPassphraseOrDamaged) == .wrongExportPassphrase)
	}

	@Test func aWrongKeyIsAWrongPassword() {
		#expect(AppModel.Failure(Unlock.Failure.wrongPassword) == .wrongPassword)
		#expect(AppModel.Failure(SQLiteError.wrongKey) == .wrongPassword)
	}
}
