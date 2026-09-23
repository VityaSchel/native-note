import Foundation

actor NoteStore {
	private static let columns = "uuid, body, createdAt, updatedAt, deleted, dirty, v, seq"

	private var opened: SQLiteConnection?

	static func open(url: URL, key: Data) async throws -> NoteStore {
		try await Task.detached(priority: .userInitiated) { try NoteStore(url: url, key: key) }.value
	}

	private init(url: URL, key: Data) throws {
		let connection = try SQLiteConnection(url: url, rawKey: key)
		try Schema.migrate(connection)
		opened = connection
	}

	func close() {
		opened = nil
	}

	private var connection: SQLiteConnection {
		get throws {
			guard let opened else { throw SQLiteError.closed }
			return opened
		}
	}

	func save(_ note: Note) throws {
		let statement = try Statement(
			"""
			INSERT INTO note (\(Self.columns)) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
			ON CONFLICT(uuid) DO UPDATE SET
				body = excluded.body,
				updatedAt = excluded.updatedAt,
				deleted = excluded.deleted,
				dirty = excluded.dirty,
				v = excluded.v,
				seq = excluded.seq
			WHERE note.deleted = 0
			""",
			on: connection.handle
		)
		statement.bind(1, note.id.bytes)
		statement.bind(2, note.body)
		statement.bind(3, note.createdAt.epochMilliseconds)
		statement.bind(4, note.updatedAt.epochMilliseconds)
		statement.bind(5, note.deleted ? 1 : 0)
		statement.bind(6, note.dirty ? 1 : 0)
		statement.bind(7, Int64(note.v))
		if let seq = note.seq { statement.bind(8, seq) } else { statement.bindNull(8) }
		try statement.step()
	}

	func checkpoint() throws {
		try connection.checkpoint()
	}

	func rekey(to newKey: Data) throws {
		try connection.rekey(to: newKey)
	}

	func note(id: UUID) throws -> Note? {
		let statement = try Statement(
			"SELECT \(Self.columns) FROM note WHERE uuid = ?1",
			on: connection.handle
		)
		statement.bind(1, id.bytes)
		return try statement.step() ? Self.note(from: statement) : nil
	}

	func liveNotes() throws -> [Note] {
		try collect(
			try Statement(
				"SELECT \(Self.columns) FROM note WHERE deleted = 0 ORDER BY updatedAt DESC",
				on: connection.handle
			)
		)
	}

	func pendingPushes() throws -> [Note] {
		try collect(
			try Statement("SELECT \(Self.columns) FROM note WHERE dirty = 1", on: connection.handle)
		)
	}

	static func matchExpression(forUserText text: String) -> String? {
		let quotableTokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
		guard !quotableTokens.isEmpty else { return nil }
		return quotableTokens.map { "\"\($0)\"" }.joined(separator: " ")
	}

	func search(_ text: String) throws -> [Note] {
		guard let expression = Self.matchExpression(forUserText: text) else { return [] }
		let statement = try Statement(
			"""
			SELECT \(Self.columns.split(separator: ", ").map { "note.\($0)" }.joined(separator: ", "))
			FROM note JOIN note_fts ON note_fts.rowid = note.rowid
			WHERE note_fts MATCH ?1 AND note.deleted = 0
			ORDER BY rank
			""",
			on: connection.handle
		)
		statement.bind(1, expression)
		return try collect(statement)
	}

	func markDeleted(id: UUID, at moment: Date) throws {
		let statement = try Statement(
			"UPDATE note SET deleted = 1, dirty = 1, body = '', updatedAt = ?2 WHERE uuid = ?1",
			on: connection.handle
		)
		statement.bind(1, id.bytes)
		statement.bind(2, moment.epochMilliseconds)
		try statement.step()
	}

	private func collect(_ statement: Statement) throws -> [Note] {
		var notes: [Note] = []
		while try statement.step() {
			if let note = Self.note(from: statement) { notes.append(note) }
		}
		return notes
	}

	private static func note(from statement: Statement) -> Note? {
		guard let id = UUID(bytes: statement.data(0)) else { return nil }
		return Note(
			id: id,
			body: statement.string(1),
			createdAt: Date(epochMilliseconds: statement.int(2)),
			updatedAt: Date(epochMilliseconds: statement.int(3)),
			deleted: statement.int(4) != 0,
			dirty: statement.int(5) != 0,
			v: UInt32(statement.int(6)),
			seq: statement.isNull(7) ? nil : statement.int(7)
		)
	}
}
