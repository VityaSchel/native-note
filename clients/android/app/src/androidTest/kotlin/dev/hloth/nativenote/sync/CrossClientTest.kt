package dev.hloth.nativenote.sync

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.SetupResult
import dev.hloth.nativenote.model.SetupStart
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CrossClientTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val arguments = InstrumentationRegistry.getArguments()

	private fun <T> main(action: suspend () -> T): T = runBlocking { withContext(Dispatchers.Main) { action() } }

	private fun AppModel.state(): String {
		val digests = onMain { notes }.map { hex(sha256(it.body.encodeToByteArray())) }.sorted()
		return hex(sha256(digests.joinToString("\n").encodeToByteArray()))
	}

	private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)

	private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

	@Test
	fun joinsALibraryMacOsWroteThenChangesIt() {
		val server = arguments.getString("crossServer")
		assumeTrue("run by devtools/android-sync-e2e/cross-client.sh", server != null)
		val apiKey = arguments.getString("crossApiKey")!!
		val phone = appModel(folder.root)
		phone.await { start() }
		phone.await { setUp("correct horse") }
		onMain { phone.finishOnboarding() }

		assertEquals(SetupResult.Ok(SetupStart.ExistingLibrary), main { phone.prepareSync(server!!, apiKey) })
		assertNull(main { phone.joinSync(server!!, apiKey, PhraseEntry(phone.mnemonic!!).set(arguments.getString("crossWords")!!, 0).first) })
		phone.await { syncNow() }
		assertEquals(SyncStatus.Phase.Idle, onMain { phone.syncStatus.phase })
		assertEquals(arguments.getString("crossExpect"), phone.state())

		val notes = onMain { phone.notes.sortedBy { it.createdAt } }
		onMain { phone.edit(notes[1].id, notes[1].body + "\nEdited on Android ✓") }
		runBlocking { onMain { phone.delete(notes[2].id) }.await() }
		phone.await { createNote("Written on Android ✓\nwith ünïcode 👍🏽 and\r\nCRLF") }
		phone.await { syncNow() }
		assertEquals(SyncStatus.Phase.Idle, onMain { phone.syncStatus.phase })
		Log.i(TAG, "state ${phone.state()}")
	}

	private companion object {
		const val TAG = "NativeNoteCrossClient"
	}
}
