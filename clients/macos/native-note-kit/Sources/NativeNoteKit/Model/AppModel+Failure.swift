import Foundation

extension AppModel {
	public enum Failure: Equatable {
		case wrongPassword
		case unsaved(String)
		case unexpected(String)

		init(_ error: Error) {
			switch error {
			case Unlock.Failure.wrongPassword, SQLiteError.wrongKey:
				self = .wrongPassword
			default:
				self = .unexpected(Self.reason(for: error))
			}
		}

		static func reason(for error: Error) -> String {
			switch error {
			case Unlock.Failure.neverSetUp:
				"No unlock parameters were found beside the notes database."
			case SQLiteError.checkpointBlocked:
				"The notes database is busy. Try again."
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
			default:
				String(describing: error)
			}
		}
	}
}
