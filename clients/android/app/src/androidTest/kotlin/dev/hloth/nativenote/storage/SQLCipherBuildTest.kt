package dev.hloth.nativenote.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SQLCipherBuildTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val key = ByteArray(32) { (it * 7 + 1).toByte() }

	private fun connection() = SQLiteConnection(File(folder.root, "notes.db"), key)

	@Test
	fun isSQLCipher4_17OnLibTomCrypt() {
		connection().use {
			assertEquals("4.17.0 community", it.scalar("PRAGMA cipher_version"))
			assertEquals("libtomcrypt", it.scalar("PRAGMA cipher_provider"))
		}
	}

	@Test
	fun keepsMacOSDefaultsWithFTS5AsTheOnlyExtra() {
		val options = connection().use { connection ->
			connection.prepare("PRAGMA compile_options").use { statement ->
				buildList { while (statement.step()) add(statement.string(0)) }
			}
		}

		assertEquals(
			listOf(
				"ATOMIC_INTRINSICS=1", "DEFAULT_AUTOVACUUM", "DEFAULT_CACHE_SIZE=-2000", "DEFAULT_FILE_FORMAT=4",
				"DEFAULT_JOURNAL_SIZE_LIMIT=1048576", "DEFAULT_MMAP_SIZE=0", "DEFAULT_PAGE_SIZE=4096", "DEFAULT_PCACHE_INITSZ=20",
				"DEFAULT_RECURSIVE_TRIGGERS", "DEFAULT_SECTOR_SIZE=4096", "DEFAULT_SYNCHRONOUS=2", "DEFAULT_WAL_AUTOCHECKPOINT=1000",
				"DEFAULT_WAL_SYNCHRONOUS=2", "DEFAULT_WORKER_THREADS=0", "DIRECT_OVERFLOW_READ", "ENABLE_FTS5",
				"EXTRA_INIT=sqlcipher_extra_init", "EXTRA_SHUTDOWN=sqlcipher_extra_shutdown", "HAS_CODEC", "MALLOC_SOFT_LIMIT=1024",
				"MAX_ATTACHED=10", "MAX_COLUMN=2000", "MAX_COMPOUND_SELECT=500", "MAX_DEFAULT_PAGE_SIZE=8192", "MAX_EXPR_DEPTH=1000",
				"MAX_FUNCTION_ARG=1000", "MAX_LENGTH=1000000000", "MAX_LIKE_PATTERN_LENGTH=50000", "MAX_MMAP_SIZE=0x7fff0000",
				"MAX_PAGE_COUNT=0xfffffffe", "MAX_PAGE_SIZE=65536", "MAX_SQL_LENGTH=1000000000", "MAX_TRIGGER_DEPTH=1000",
				"MAX_VARIABLE_NUMBER=32766", "MAX_VDBE_OP=250000000", "MAX_WORKER_THREADS=8", "MUTEX_PTHREADS", "OMIT_DEPRECATED",
				"OMIT_JSON", "OMIT_LOAD_EXTENSION", "OMIT_SHARED_CACHE", "SYSTEM_MALLOC", "TEMP_STORE=2", "THREADSAFE=1",
			),
			options.filterNot { it.startsWith("COMPILER=") },
		)
	}

	@Test
	fun fullTextSearchUsesFTS5() {
		connection().use {
			it.execute("CREATE VIRTUAL TABLE note_fts USING fts5(body)")
			it.execute("INSERT INTO note_fts (body) VALUES ('groceries: milk, bread'), ('meeting notes')")

			assertEquals("groceries: milk, bread", it.scalar("SELECT body FROM note_fts WHERE note_fts MATCH 'bread'"))
		}
	}

	@Test
	fun theRawKeyReopensTheLibraryAndAnotherKeyIsRefused() {
		val file = File(folder.root, "notes.db")
		SQLiteConnection(file, key).use { it.execute("CREATE TABLE note (body TEXT NOT NULL); INSERT INTO note VALUES ('kept')") }

		assertEquals("kept", SQLiteConnection(file, key).use { it.scalar("SELECT body FROM note") })
		val refused = runCatching { SQLiteConnection(file, key.reversedArray()) }.exceptionOrNull() as SQLiteException
		assertEquals(26, refused.code)
	}

	@Test
	fun theFileOnDiskIsNotSQLite() {
		val file = File(folder.root, "notes.db")
		SQLiteConnection(file, key).use { it.execute("CREATE TABLE note (body TEXT NOT NULL); INSERT INTO note VALUES ('plain words')") }

		val bytes = file.readBytes()
		assertEquals(false, bytes.decodeToString().contains("SQLite format 3"))
		assertEquals(false, bytes.decodeToString().contains("plain words"))
	}

	@Test
	fun textAndBlobsRoundTripByteForByte() {
		val text = "Title 🙂 with 𝄞, CR\r\nLF and a NUL \u0000 inside"
		val blob = byteArrayOf(0, -1, 0x7f, 0)
		connection().use { connection ->
			connection.execute("CREATE TABLE value (text TEXT, blob BLOB, empty BLOB, missing TEXT)")
			connection.prepare("INSERT INTO value VALUES (?, ?, ?, ?)").use {
				it.bind(1, text)
				it.bind(2, blob)
				it.bind(3, ByteArray(0))
				it.bind(4, null as String?)
				it.step()
			}

			connection.prepare("SELECT text, blob, empty, missing FROM value").use {
				it.step()
				assertEquals(text, it.string(0))
				assertEquals(blob.toList(), it.bytes(1).toList())
				assertEquals(0, it.bytes(2).size)
				assertEquals(true, it.isNull(3))
			}
		}
	}

	@Test
	fun failuresCarrySQLiteCodeAndMessage() {
		connection().use {
			val syntax = runCatching { it.execute("CREATE TABEL note (body TEXT)") }.exceptionOrNull() as SQLiteException
			assertEquals(1, syntax.code)
			assertEquals("near \"TABEL\": syntax error", syntax.message)
		}

		val missing = runCatching { SQLiteConnection(File(folder.root, "missing.db"), key, create = false) }.exceptionOrNull() as SQLiteException
		assertEquals(14, missing.code)
	}
}
