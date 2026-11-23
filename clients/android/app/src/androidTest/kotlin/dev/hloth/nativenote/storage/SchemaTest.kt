package dev.hloth.nativenote.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SchemaTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val key = ByteArray(32) { (it * 11 + 2).toByte() }

	private fun connection() = SQLiteConnection(File(folder.root, "notes.db"), key)

	@Test
	fun createsTheSchemaOnceAndRecordsItsVersion() {
		connection().use { Schema.prepare(it) }
		connection().use {
			Schema.prepare(it)

			assertEquals(Schema.VERSION.toString(), it.scalar("PRAGMA user_version"))
			assertEquals("uuid,body,createdAt,updatedAt,deleted,dirty,v,pulled,ext", it.scalar("SELECT group_concat(name, ',') FROM pragma_table_info('note')"))
			assertEquals("k,v", it.scalar("SELECT group_concat(name, ',') FROM pragma_table_info('meta')"))
			assertEquals("note_dirty,note_updatedAt", it.scalar("SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_schema WHERE type = 'index' AND tbl_name = 'note' AND sql IS NOT NULL ORDER BY name)"))
			assertEquals("0", it.scalar("SELECT count(*) FROM note"))
		}
	}

	@Test
	fun refusesADatabaseFromANewerVersion() {
		connection().use {
			Schema.prepare(it)
			it.execute("PRAGMA user_version = ${Schema.VERSION + 1}")
		}

		val refused = connection().use { connection -> assertThrows(Schema.NewerSchema::class.java) { Schema.prepare(connection) } }

		assertEquals(Schema.VERSION + 1, refused.found)
	}

	@Test
	fun aFailedCreationLeavesTheVersionUnchanged() {
		connection().use {
			it.execute("CREATE TABLE note_dirty (x)")

			assertThrows(SQLiteException::class.java) { Schema.prepare(it) }
			assertEquals("0", it.scalar("PRAGMA user_version"))
			assertEquals("0", it.scalar("SELECT count(*) FROM sqlite_schema WHERE name = 'note'"))
		}
	}

	@Test
	fun theSearchIndexFollowsEveryInsertUpdateAndDelete() {
		connection().use { connection ->
			Schema.prepare(connection)
			fun matches(term: String) = connection.scalar("SELECT count(*) FROM note_fts WHERE note_fts MATCH '$term'")

			connection.execute("INSERT INTO note (uuid, body, createdAt, updatedAt) VALUES (x'01', 'groceries: bread', 1, 1)")
			assertEquals("1", matches("bread"))
			connection.execute("UPDATE note SET body = 'groceries: milk' WHERE uuid = x'01'")
			assertEquals("0", matches("bread"))
			assertEquals("1", matches("milk"))
			connection.execute("DELETE FROM note WHERE uuid = x'01'")
			assertEquals("0", matches("milk"))
		}
	}

	@Test
	fun columnsAreStrict() {
		connection().use {
			Schema.prepare(it)

			assertThrows(SQLiteException::class.java) {
				it.execute("INSERT INTO note (uuid, body, createdAt, updatedAt) VALUES (x'02', 'body', 'yesterday', 1)")
			}
		}
	}
}
