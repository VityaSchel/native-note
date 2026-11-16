import Foundation

nonisolated enum Schema {
	static let version = 1

	static func prepare(_ connection: SQLiteConnection) throws {
		let found = Int(try connection.scalar("PRAGMA user_version").flatMap(Int.init) ?? 0)
		guard found <= version else { throw SQLiteError.newerSchema(found: found, known: version) }
		guard found < version else { return }
		try connection.transaction {
			try connection.execute(definition)
			try connection.execute("PRAGMA user_version = \(version)")
		}
	}

	static let definition = """
		CREATE TABLE note (
			uuid      BLOB    PRIMARY KEY NOT NULL,
			body      TEXT    NOT NULL,
			createdAt INTEGER NOT NULL,
			updatedAt INTEGER NOT NULL,
			deleted   INTEGER NOT NULL DEFAULT 0,
			dirty     INTEGER NOT NULL DEFAULT 0,
			v         INTEGER NOT NULL DEFAULT 0,
			pulled    INTEGER NOT NULL DEFAULT 0,
			ext       BLOB    NOT NULL DEFAULT x''
		) STRICT;

		CREATE INDEX note_updatedAt ON note (updatedAt DESC);
		CREATE INDEX note_dirty ON note (dirty) WHERE dirty = 1;

		CREATE VIRTUAL TABLE note_fts USING fts5(body, content=note);

		CREATE TRIGGER note_fts_insert AFTER INSERT ON note BEGIN
			INSERT INTO note_fts (rowid, body) VALUES (new.rowid, new.body);
		END;

		CREATE TRIGGER note_fts_delete AFTER DELETE ON note BEGIN
			INSERT INTO note_fts (note_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
		END;

		CREATE TRIGGER note_fts_update AFTER UPDATE ON note BEGIN
			INSERT INTO note_fts (note_fts, rowid, body) VALUES ('delete', old.rowid, old.body);
			INSERT INTO note_fts (rowid, body) VALUES (new.rowid, new.body);
		END;

		CREATE TABLE meta (
			k TEXT PRIMARY KEY NOT NULL,
			v BLOB NOT NULL
		) STRICT;
		"""
}
