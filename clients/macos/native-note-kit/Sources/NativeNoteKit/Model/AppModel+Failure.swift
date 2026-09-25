import Foundation

extension AppModel {
	public enum Failure: Equatable {
		case wrongPassword
		case wrongExportPassphrase
		case unsaved(String)
		case unexpected(String)

		init(_ error: Error) {
			switch error {
			case Unlock.Failure.wrongPassword, SQLiteError.wrongKey:
				self = .wrongPassword
			case ExportEnvelope.Failure.wrongPassphraseOrDamaged:
				self = .wrongExportPassphrase
			default:
				self = .unexpected(Self.reason(for: error))
			}
		}

		static func reason(for error: Error) -> String {
			switch error {
			case Unlock.Failure.neverSetUp:
				"No unlock parameters were found beside the notes database."
			case Unlock.Failure.alreadySetUp:
				"Native Note is already set up."
			case Unlock.Failure.databaseMissing:
				"The notes database is missing."
			case Unlock.Failure.boundToAnotherMac:
				"These notes are bound to another Mac's Secure Enclave and cannot open here. Restore them from an export."
			case Unlock.Failure.passwordNotChanged:
				"Password not changed. Try again."
			case Unlock.Failure.storedKeyRejected:
				"The key saved for Touch ID no longer opens these notes. Unlock with your password."
			case AppLock.Unreadable.unsupportedVersion:
				"The unlock parameters were written by a newer version of Native Note. Update the app to open them."
			case is DecodingError:
				"The unlock parameters file is damaged."
			case LibraryArchive.Failure.tooLarge:
				"The file is too large to be a Native Note export."
			case ZipArchive.Failure.tooLarge:
				"The library is too large to export as one zip."
			case ExportEnvelope.Failure.parametersOutOfBounds:
				"The export asks for more memory or time than Native Note allows."
			case ExportEnvelope.Failure.notAnExport, is ZipArchive.Failure, is NoteMarkdown.Failure, is LibraryArchive.Failure:
				"This file is not a Native Note export, or it is damaged."
			case SQLiteError.closed:
				"The notes database is closed."
			case SQLiteError.newerSchema:
				"The notes database was written by a newer version of Native Note. Update the app to open it."
			case let SQLiteError.cannotOpen(_, message):
				"The notes database could not be opened. \(message)"
			case let SQLiteError.cannotExecute(_, message, _):
				message
			case let SQLiteError.keyMustBe32Bytes(count):
				"The unlock key was \(count) bytes rather than 32."
			case let error as CocoaError:
				error.localizedDescription
			default:
				String(describing: error)
			}
		}
	}
}
