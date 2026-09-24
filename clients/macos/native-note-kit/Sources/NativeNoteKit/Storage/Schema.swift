import Foundation

nonisolated enum Schema {
	static let migrations = [version1]

	static func migrate(_ connection: SQLiteConnection) throws {
		let applied = Int(try connection.scalar("PRAGMA user_version").flatMap(Int.init) ?? 0)
		guard applied <= migrations.count else {
			throw SQLiteError.newerSchema(found: applied, known: migrations.count)
		}
		guard applied < migrations.count else { return }

		try connection.transaction {
			for (index, migration) in migrations.enumerated() where index >= applied {
				try connection.execute(migration)
			}
			try connection.execute("PRAGMA user_version = \(migrations.count)")
		}
	}

	private static let version1 = """
		CREATE TABLE note (
			uuid      BLOB    PRIMARY KEY NOT NULL,
			body      TEXT    NOT NULL,
			createdAt INTEGER NOT NULL,
			updatedAt INTEGER NOT NULL,
			deleted   INTEGER NOT NULL DEFAULT 0,
			dirty     INTEGER NOT NULL DEFAULT 0,
			v         INTEGER NOT NULL DEFAULT 0,
			seq       INTEGER
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
