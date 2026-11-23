package dev.hloth.nativenote.storage

object Schema {
	const val VERSION = 1

	class NewerSchema(val found: Int) : Exception("the library was written by a newer Native Note, schema $found, this app knows $VERSION")

	fun prepare(connection: SQLiteConnection) {
		val found = connection.scalar("PRAGMA user_version")?.toInt() ?: 0
		if (found > VERSION) throw NewerSchema(found)
		if (found == VERSION) return
		connection.transaction {
			connection.execute(DEFINITION)
			connection.execute("PRAGMA user_version = $VERSION")
		}
	}

	private val DEFINITION = """
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
	""".trimIndent()
}
