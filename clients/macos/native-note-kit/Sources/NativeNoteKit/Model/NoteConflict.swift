import Foundation

nonisolated public struct NoteConflict: Identifiable, Equatable, Sendable {
	public enum Choice: Sendable {
		case keepMine
		case keepTheirs
	}

	public let mine: Note
	public let theirs: Note

	public var id: UUID { mine.id }
}

nonisolated public struct ImportSummary: Equatable, Sendable {
	public var added = 0
	public var unchanged = 0
	public var conflicting = 0
	public var deletedHere = 0
	public var notImported = 0
}
