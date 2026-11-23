package dev.hloth.nativenote.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SQLiteConnectionTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val key = ByteArray(32) { (it * 3 + 5).toByte() }
	private val database get() = File(folder.root, "notes.db")

	private fun connection(create: Boolean = true) = SQLiteConnection(database, key, create)

	private class Planted : Exception()

	@Test
	fun everyOpenSyncsFullyInWALAndEnforcesForeignKeys() {
		repeat(2) {
			connection().use {
				assertEquals("2", it.scalar("PRAGMA synchronous"))
				assertEquals("wal", it.scalar("PRAGMA journal_mode"))
				assertEquals("1", it.scalar("PRAGMA foreign_keys"))
				assertEquals("5000", it.scalar("PRAGMA busy_timeout"))
			}
		}
	}

	@Test
	fun closingLeavesOnlyTheDatabaseFile() {
		val connection = connection()
		connection.execute("CREATE TABLE note (body TEXT); INSERT INTO note VALUES ('kept')")
		assertTrue(File(folder.root, "notes.db-wal").exists())

		connection.close()

		assertEquals(listOf("notes.db"), folder.root.list()!!.toList())
		assertEquals("kept", connection(create = false).use { it.scalar("SELECT body FROM note") })
	}

	@Test
	fun refusesAPathItCannotOpenWithoutCreatingIt() {
		val missing = File(folder.root, "missing/notes.db")

		val refused = assertThrows(SQLiteException::class.java) { SQLiteConnection(missing, key) }

		assertEquals(14, refused.code)
		assertFalse(missing.parentFile!!.exists())
	}

	@Test
	fun aThrowingTransactionRollsBackAndRethrows() {
		connection().use { connection ->
			val probeCount = "SELECT count(*) FROM sqlite_schema WHERE name = 'probe'"

			assertThrows(Planted::class.java) {
				connection.transaction {
					connection.execute("CREATE TABLE probe (x)")
					throw Planted()
				}
			}
			assertEquals("0", connection.scalar(probeCount))

			connection.transaction { connection.execute("CREATE TABLE probe (x)") }
			assertEquals("1", connection.scalar(probeCount))
		}
	}

	@Test
	fun aDatabaseHeldExclusivelyIsBusyRatherThanAWrongKey() {
		connection().use { holder ->
			holder.execute("PRAGMA locking_mode = EXCLUSIVE")
			holder.execute("BEGIN EXCLUSIVE")
			holder.execute("CREATE TABLE held (x)")

			val busy = assertThrows(SQLiteException::class.java) { connection() }

			assertEquals(5, busy.code)
			holder.execute("ROLLBACK")
		}
	}

	@Test
	fun aWriteWaitsForAnotherConnectionsTransaction() {
		connection().use { waiting ->
			waiting.execute("CREATE TABLE written (x)")
			val holds = CountDownLatch(1)
			val holding = thread {
				connection(create = false).use { holder ->
					holder.execute("BEGIN IMMEDIATE")
					holder.execute("INSERT INTO written VALUES ('holder')")
					holds.countDown()
					Thread.sleep(300)
					holder.execute("COMMIT")
				}
			}
			holds.await()

			waiting.execute("INSERT INTO written VALUES ('waiter')")

			holding.join()
			assertEquals("holder,waiter", waiting.scalar("SELECT group_concat(x) FROM written"))
		}
	}

	@Test
	fun anEmptyBlobBindsAsABlobNotNull() {
		connection().use { connection ->
			connection.prepare("SELECT typeof(?1), typeof(?2), length(?1)").use {
				it.bind(1, ByteArray(0))
				it.bind(2, "")

				assertTrue(it.step())
				assertEquals("blob", it.string(0))
				assertEquals("text", it.string(1))
				assertEquals(0L, it.long(2))
			}
		}
	}

	@Test
	fun aBindingThatDoesNotLandIsAnError() {
		connection().use { connection ->
			connection.prepare("SELECT ?1").use {
				assertEquals(25, assertThrows(SQLiteException::class.java) { it.bind(2, byteArrayOf(1)) }.code)
				assertThrows(SQLiteException::class.java) { it.bind(2, "text") }
				assertThrows(SQLiteException::class.java) { it.bind(2, 1L) }
				assertThrows(SQLiteException::class.java) { it.bind(2, null as String?) }
			}
		}
	}

	@Test
	fun scalarWithoutARowIsNullAndNullReadsAsEmpty() {
		connection().use { connection ->
			assertNull(connection.scalar("SELECT 1 WHERE 0"))
			assertEquals("", connection.scalar("SELECT NULL"))
			connection.prepare("SELECT missing, missing FROM (SELECT NULL AS missing)").use {
				assertTrue(it.step())
				assertTrue(it.isNull(0))
				assertEquals(0, it.bytes(0).size)
				assertEquals("", it.string(1))
			}
		}
	}

	@Test
	fun aClosedConnectionOrStatementRefusesUse() {
		val connection = connection()
		val statement = connection.prepare("SELECT 1")
		statement.close()
		connection.close()

		assertThrows(IllegalStateException::class.java) { statement.step() }
		assertThrows(IllegalStateException::class.java) { connection.execute("SELECT 1") }
	}
}
