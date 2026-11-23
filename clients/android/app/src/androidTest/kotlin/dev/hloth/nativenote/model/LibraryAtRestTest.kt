package dev.hloth.nativenote.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockRecordFile
import java.io.ByteArrayOutputStream
import java.util.UUID
import java.util.zip.Deflater
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryAtRestTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"

	@Test
	fun aLockedLibraryOnDiskIsIndistinguishableFromRandom() {
		val files = LibraryFiles(folder.root)
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp(password) }
		val bodies = RealisticCorpus.bodies(600)
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { connection ->
			val store = NoteStore(connection)
			connection.transaction {
				bodies.forEachIndexed { index, body -> store.put(Note(UUID.randomUUID(), body, index.toLong(), index.toLong(), dirty = true), pulled = false) }
			}
		}
		model.await { lock() }
		model.await { unlock(password) }
		model.await { lock() }

		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), folder.root.list()!!.sorted())
		val database = files.database.readBytes()
		assertTrue("the library holds the corpus", database.size > 1_000_000)
		assertFalse(database.startsWith("SQLite format 3".encodeToByteArray()))
		assertTrue("chi-square ${chiSquare(database)}", chiSquare(database) < 400)
		assertTrue("compressed to ${compressed(database).toDouble() / database.size}", compressed(database) >= database.size * 99L / 100)
		for (word in listOf("quartz", "Lisbon", "kettle", "meeting", "Shopping", "Käsespätzle", "item 1", "front-matter")) {
			assertTrue("the corpus holds \"$word\"", bodies.any { word in it })
			assertFalse("\"$word\" is readable at rest", database.contains(word.encodeToByteArray()))
		}
	}

	private fun chiSquare(bytes: ByteArray): Double {
		val counts = LongArray(256)
		for (byte in bytes) counts[byte.toInt() and 0xFF]++
		val expected = bytes.size / 256.0
		return counts.sumOf { (it - expected) * (it - expected) / expected }
	}

	private fun compressed(bytes: ByteArray): Long {
		val deflater = Deflater(Deflater.BEST_COMPRESSION).apply {
			setInput(bytes)
			finish()
		}
		val buffer = ByteArray(1 shl 16)
		val output = ByteArrayOutputStream()
		while (!deflater.finished()) output.write(buffer, 0, deflater.deflate(buffer))
		deflater.end()
		return output.size().toLong()
	}

	private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

	private fun ByteArray.contains(needle: ByteArray): Boolean {
		outer@ for (start in 0..size - needle.size) {
			for (offset in needle.indices) if (this[start + offset] != needle[offset]) continue@outer
			return true
		}
		return false
	}
}
