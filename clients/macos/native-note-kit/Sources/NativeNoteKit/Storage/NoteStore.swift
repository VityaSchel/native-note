import CryptoKit
import Foundation

actor NoteStore {
	static let columns = "uuid, body, createdAt, updatedAt, deleted, dirty, v, seq"

	private let url: URL
	private var opened: SQLiteConnection?

	static func create(url: URL, key: SymmetricKey) async throws -> NoteStore {
		try await connect(url: url, key: key, create: true)
	}

	static func open(url: URL, key: SymmetricKey) async throws -> NoteStore {
		try await connect(url: url, key: key, create: false)
	}

	private static func connect(url: URL, key: SymmetricKey, create: Bool) async throws -> NoteStore {
		try await Task.detached(priority: .userInitiated) { try NoteStore(url: url, key: key, create: create) }.value
	}

	private init(url: URL, key: SymmetricKey, create: Bool) throws {
		let connection = try SQLiteConnection(url: url, rawKey: key, create: create)
		try Schema.migrate(connection)
		self.url = url
		opened = connection
	}

	func close() {
		opened = nil
	}

	var connection: SQLiteConnection {
		get throws {
			guard let opened else { throw SQLiteError.closed }
			return opened
		}
	}

	enum Saved: Equatable {
		case saved
		/// A pull replaced the note after the edit began, at the `v` the note carries, so the edit became this new note.
		case copied(UUID)
	}

	/// Writes a local edit, never `v`, never over a tombstone, and never over text a pull wrote after the edit began.
	@discardableResult
	func save(_ note: Note) throws -> Saved {
		try connection.transaction {
			let held = try connection.prepare("SELECT v, pulled FROM note WHERE uuid = ?1")
			held.bind(1, note.id.bytes)
			guard try held.step() else {
				try put(note, pulled: false)
				return .saved
			}
			if held.int(0) != Int64(note.v), held.int(1) != 0 {
				let copy = Note(id: UUID(), body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt, dirty: true)
				try put(copy, pulled: false)
				return .copied(copy.id)
			}
			let statement = try connection.prepare(
				"UPDATE note SET body = ?2, updatedAt = ?3, deleted = ?4, dirty = ?5, pulled = 0 WHERE uuid = ?1 AND deleted = 0"
			)
			statement.bind(1, note.id.bytes)
			statement.bind(2, note.body)
			statement.bind(3, note.updatedAt)
			statement.bind(4, note.deleted ? 1 : 0)
			statement.bind(5, note.dirty ? 1 : 0)
			try statement.step()
			return .saved
		}
	}

	/// Writes every column, tombstones included, unlike a local save.
	func put(_ note: Note, pulled: Bool) throws {
		let statement = try connection.prepare(
			"""
			INSERT INTO note (\(Self.columns), pulled) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
			ON CONFLICT(uuid) DO UPDATE SET
				body = excluded.body,
				createdAt = excluded.createdAt,
				updatedAt = excluded.updatedAt,
				deleted = excluded.deleted,
				dirty = excluded.dirty,
				v = excluded.v,
				pulled = excluded.pulled
			"""
		)
		statement.bind(1, note.id.bytes)
		statement.bind(2, note.body)
		statement.bind(3, note.createdAt)
		statement.bind(4, note.updatedAt)
		statement.bind(5, note.deleted ? 1 : 0)
		statement.bind(6, note.dirty ? 1 : 0)
		statement.bind(7, Int64(note.v))
		if let seq = note.seq { statement.bind(8, seq) } else { statement.bindNull(8) }
		statement.bind(9, pulled ? 1 : 0)
		try statement.step()
	}

	func rekey(from oldKey: SymmetricKey, to newKey: SymmetricKey) throws -> Bool {
		try connection.rekey(to: newKey)
		do {
			_ = try SQLiteConnection(url: url, rawKey: newKey, create: false)
			return true
		} catch SQLiteError.wrongKey {
			opened = nil
			opened = try SQLiteConnection(url: url, rawKey: oldKey, create: false)
			return false
		}
	}

	func note(id: UUID) throws -> Note? {
		let statement = try connection.prepare(
			"SELECT \(Self.columns) FROM note WHERE uuid = ?1"
		)
		statement.bind(1, id.bytes)
		return try statement.step() ? Self.note(from: statement) : nil
	}

	func liveNotes() throws -> [Note] {
		try collect(
			try connection.prepare(
				"SELECT \(Self.columns) FROM note WHERE deleted = 0 ORDER BY updatedAt DESC"
			)
		)
	}

	func pendingPushes() throws -> [Note] {
		try collect(
			try connection.prepare("SELECT \(Self.columns) FROM note WHERE dirty = 1")
		)
	}

	private static func matchExpression(forUserText text: String) -> String? {
		let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
		guard let last = tokens.last else { return nil }
		let phrases = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\"", options: .literal))\"" }.joined(separator: " ")
		return last.count >= 2 ? phrases + "*" : phrases
	}

	func search(_ text: String) throws -> [Note] {
		guard let expression = Self.matchExpression(forUserText: text) else { return [] }
		let statement = try connection.prepare(
			"""
			SELECT \(Self.columns.split(separator: ", ").map { "note.\($0)" }.joined(separator: ", "))
			FROM note JOIN note_fts ON note_fts.rowid = note.rowid
			WHERE note_fts MATCH ?1 AND note.deleted = 0
			ORDER BY rank
			"""
		)
		statement.bind(1, expression)
		return try collect(statement)
	}

	func markDeleted(id: UUID, at moment: Int64) throws {
		let statement = try connection.prepare(
			"UPDATE note SET deleted = 1, dirty = 1, body = '', updatedAt = ?2, pulled = 0 WHERE uuid = ?1"
		)
		statement.bind(1, id.bytes)
		statement.bind(2, moment)
		try statement.step()
	}

	func collect(_ statement: SQLiteStatement) throws -> [Note] {
		var notes: [Note] = []
		while try statement.step() {
			if let note = Self.note(from: statement) { notes.append(note) }
		}
		return notes
	}

	static func note(from statement: SQLiteStatement) -> Note? {
		guard let id = UUID(bytes: statement.data(0)) else { return nil }
		return Note(
			id: id,
			body: statement.string(1),
			createdAt: statement.int(2),
			updatedAt: statement.int(3),
			deleted: statement.int(4) != 0,
			dirty: statement.int(5) != 0,
			v: UInt32(statement.int(6)),
			seq: statement.isNull(7) ? nil : statement.int(7)
		)
	}
}
