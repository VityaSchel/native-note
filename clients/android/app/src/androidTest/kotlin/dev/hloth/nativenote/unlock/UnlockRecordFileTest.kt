package dev.hloth.nativenote.unlock

import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UnlockRecordFileTest {
	@get:Rule
	val folder = TemporaryFolder()

	private fun record() = UnlockRecord(UnlockParameters(AesGcm.randomBytes(16), Argon2.Parameters.floor, AesGcm.randomBytes(16)), AesGcm.randomBytes(60))

	@Test
	fun aMissingRecordReadsAsNone() {
		assertNull(UnlockRecordFile.inDirectory(folder.root).read())
	}

	@Test
	fun eachWriteReplacesTheRecordWholeAndLeavesNoTemporaryFile() {
		val store = UnlockRecordFile.inDirectory(folder.root)
		val first = record()
		val second = record()

		store.write(first)
		assertEquals(first, store.read())
		store.write(second)

		assertEquals(second, UnlockRecordFile.inDirectory(folder.root).read())
		assertEquals(listOf(UnlockRecordFile.NAME), folder.root.list()!!.toList())
		assertEquals("600", Integer.toOctalString(Os.stat(store.file.path).st_mode and 0b111_111_111))
	}

	@Test
	fun anUnreadableRecordIsAnErrorNeverAFirstRun() {
		val store = UnlockRecordFile.inDirectory(folder.root)
		store.file.writeBytes(record().encoded().copyOf(40))

		assertThrows(UnlockRecord.Unreadable::class.java) { store.read() }
	}

	@Test
	fun deletingRemovesTheRecordAndIsQuietWhenNoneIsThere() {
		val store = UnlockRecordFile.inDirectory(folder.root)
		store.write(record())

		store.delete()
		store.delete()

		assertNull(store.read())
		assertEquals(false, File(folder.root, UnlockRecordFile.NAME).exists())
	}
}
