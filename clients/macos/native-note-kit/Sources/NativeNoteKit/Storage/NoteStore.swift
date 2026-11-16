import CryptoKit
import Foundation

actor NoteStore {
	static let columns = "uuid, body, createdAt, updatedAt, deleted, dirty, v, ext"

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
		case copied(UUID)
	}

	@discardableResult
	func save(_ note: Note) throws -> Saved {
		try connection.transaction {
			let held = try connection.prepare("SELECT 1 FROM note WHERE uuid = ?1")
			try held.bind(1, note.id.bytes)
			guard try held.step() else {
				try put(note, pulled: false)
				return .saved
			}
			if try wasPulled(note.id, after: note.v) {
				let copy = note.unsyncedCopy()
				try put(copy, pulled: false)
				return .copied(copy.id)
			}
			let statement = try connection.prepare(
				"UPDATE note SET body = ?2, updatedAt = ?3, deleted = ?4, dirty = ?5, pulled = 0 WHERE uuid = ?1 AND deleted = 0"
			)
			try statement.bind(1, note.id.bytes)
			try statement.bind(2, note.body)
			try statement.bind(3, note.updatedAt)
			try statement.bind(4, note.deleted ? 1 : 0)
			try statement.bind(5, note.dirty ? 1 : 0)
			try statement.step()
			return .saved
		}
	}

	private static let insertion = "INSERT INTO note (\(columns), pulled) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"

	func put(_ note: Note, pulled: Bool) throws {
		let statement = try connection.prepare(
			"""
			\(Self.insertion)
			ON CONFLICT(uuid) DO UPDATE SET
				body = excluded.body,
				createdAt = excluded.createdAt,
				updatedAt = excluded.updatedAt,
				deleted = excluded.deleted,
				dirty = excluded.dirty,
				v = excluded.v,
				ext = excluded.ext,
				pulled = excluded.pulled
			"""
		)
		try Self.bind(note, pulled: pulled, to: statement)
		try statement.step()
	}

	func insertMissing(_ notes: [Note]) throws -> [Note] {
		try connection.transaction {
			let statement = try connection.prepare("\(Self.insertion) ON CONFLICT(uuid) DO NOTHING RETURNING uuid")
			return try notes.filter { note in
				defer { statement.reset() }
				try Self.bind(note, pulled: false, to: statement)
				return try statement.step()
			}
		}
	}

	private static func bind(_ note: Note, pulled: Bool, to statement: SQLiteStatement) throws {
		try statement.bind(1, note.id.bytes)
		try statement.bind(2, note.body)
		try statement.bind(3, note.createdAt)
		try statement.bind(4, note.updatedAt)
		try statement.bind(5, note.deleted ? 1 : 0)
		try statement.bind(6, note.dirty ? 1 : 0)
		try statement.bind(7, Int64(note.v))
		try statement.bind(8, note.ext)
		try statement.bind(9, pulled ? 1 : 0)
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
		try statement.bind(1, id.bytes)
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
		try statement.bind(1, expression)
		return try collect(statement)
	}

	func discardUnsynced(id: UUID, shownAt v: UInt32, at moment: Int64) throws {
		try connection.transaction {
			let neverPushed = try connection.prepare("DELETE FROM note WHERE uuid = ?1 AND v = 0 RETURNING uuid")
			try neverPushed.bind(1, id.bytes)
			guard try !neverPushed.step() else { return }
			guard try !wasPulled(id, after: v) else { return }
			try markDeleted(id: id, at: moment)
		}
	}

	private func wasPulled(_ id: UUID, after shown: UInt32) throws -> Bool {
		let statement = try connection.prepare("SELECT 1 FROM note WHERE uuid = ?1 AND pulled = 1 AND v != ?2")
		try statement.bind(1, id.bytes)
		try statement.bind(2, Int64(shown))
		return try statement.step()
	}

	func markDeleted(id: UUID, at moment: Int64) throws {
		let statement = try connection.prepare(
			"""
			INSERT INTO note (uuid, body, createdAt, updatedAt, deleted, dirty, pulled) VALUES (?1, '', ?2, ?2, 1, 0, 0)
			ON CONFLICT(uuid) DO UPDATE SET deleted = 1, dirty = 1, body = '', ext = x'', updatedAt = ?2, pulled = 0
			"""
		)
		try statement.bind(1, id.bytes)
		try statement.bind(2, moment)
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
			ext: statement.data(7)
		)
	}
}
