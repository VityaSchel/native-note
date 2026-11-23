package dev.hloth.nativenote.threatmodel

import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.DatabaseKeyWrap
import dev.hloth.nativenote.crypto.KeyDerivation
import dev.hloth.nativenote.crypto.MachineKey
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.cheapArgon
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockRecordFile
import java.io.IOException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BoundaryTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse"
	private val files get() = LibraryFiles(folder.root)

	private fun unlocked(vararg bodies: String, model: AppModel = appModel(folder.root)): AppModel {
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in bodies) model.await { createNote(body) }
		onMain { model.select(null) }
		return model
	}

	@Test
	fun lockingDropsWhatTheUnlockedLibraryHeld() {
		val model = unlocked("while unlocked", model = appModel(folder.root, makeTransport = { SyncTransport { throw IOException("offline") } }))
		model.await { lock() }
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use {
			NoteStore(it).enableSync(SyncSettings("http://127.0.0.1:9/", AesGcm.randomBytes(32), AesGcm.randomBytes(32)), 1u)
		}
		model.await { unlock(password) }
		assertNotEquals(SyncStatus.Phase.Off, onMain { model.syncStatus.phase })

		model.await { lock() }

		onMain {
			assertEquals(AppModel.Phase.Locked, model.phase)
			assertEquals(emptyList<Any>(), model.notes)
			assertNull(model.selection)
			assertEquals(SyncStatus(), model.syncStatus)
		}
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), folder.root.list()!!.sorted())
	}

	@Test
	fun aDeletedNoteLeavesNoPlaintextOnDisk() {
		val model = unlocked("quartzite zephyr deleted", "kept")
		runBlocking { onMain { model.delete(model.notes.first { it.body.startsWith("quartzite") }.id) }.await() }

		model.await { lock() }

		for (file in folder.root.listFiles()!!) {
			assertFalse(file.name, file.readBytes().decodeToString(throwOnInvalidSequence = false).contains("quartzite"))
		}
	}

	@Test
	fun anyNumberOfWrongPasswordsLeavesTheRightOneWorking() {
		val model = unlocked("still here")
		model.await { lock() }

		repeat(25) { attempt ->
			model.await { unlock("wrong $attempt") }
			assertEquals(Failure.WrongPassword, onMain { model.failure })
		}
		model.await { unlock(password) }

		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
		assertEquals(listOf("still here"), onMain { model.notes.map { it.body } })
	}

	@Test
	fun aLibraryWithoutHardwareBindingCanBeGuessedFromItsFilesAlone() {
		val model = unlocked("guessable")
		model.await { lock() }
		val record = files.record.read()!!
		assertNull(record.parameters.machineKeyId)

		val found = listOf("123456", "password", "letmein", password, "qwerty").firstOrNull { guess ->
			val key = runCatching { UnlockKeys.databaseKey(guess, record) }.getOrNull() ?: return@firstOrNull false
			runCatching { SQLiteConnection(files.database, key, create = false).use { it.scalar("SELECT count(*) FROM note") } }.getOrNull() == "1"
		}

		assertEquals(password, found)
	}

	@Test
	fun withTheMachineIdReadOnceGuessingCostsOnlyArgon2() {
		val strongBox = InstrumentationRegistry.getInstrumentation().targetContext.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
		unlocked(model = appModel(folder.root, makeParameters = { UnlockKeys.makeParameters(strongBox) { cheapArgon } })).await { lock() }
		val record = files.record.read()!!
		val machineKeyId = record.parameters.machineKeyId
		assumeTrue("needs a hardware-backed machine key", machineKeyId != null)

		val machineId = MachineKey.load(machineKeyId!!).machineId()
		val found = listOf("123456", "password", password, "qwerty").firstOrNull { guess ->
			val argon = Argon2.hash(guess, record.parameters.localSalt, record.parameters.argon)
			val unlockKey = KeyDerivation.unlockKey(argon, machineId, record.parameters.localSalt)
			DatabaseKeyWrap.unwrap(record.wrappedKey, unlockKey) != null
		}

		assertEquals(password, found)
	}
}
