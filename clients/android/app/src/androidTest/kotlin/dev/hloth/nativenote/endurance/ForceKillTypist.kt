package dev.hloth.nativenote.endurance

import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ForceKillTypist {
	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val step = InstrumentationRegistry.getArguments().getString("forceKill")
	private val directory = File(context.filesDir, "force-kill")
	private val log = File(context.filesDir, "force-kill.log")
	private val password = "force kill typist"
	private val text = Random(1).let { random -> buildString { while (length < 8_000) append(WORDS.random(random)).append(' ') } }

	@Test
	fun type() {
		assumeTrue("run by devtools/android-force-kill", step == "type")
		directory.mkdirs()
		LibraryFiles(directory).erase()
		log.delete()
		val model = appModel(directory)
		model.await { start() }
		model.await { setUp(password) }
		model.await { createNote() }
		val id = onMain { model.selection!! }
		log.outputStream().bufferedWriter().use { written ->
			for (length in 1..text.length) {
				onMain { model.edit(id, text.substring(0, length)) }
				written.write("${SystemClock.elapsedRealtime()} $length\n")
				written.flush()
				Thread.sleep(TYPING_INTERVAL_MILLISECONDS)
			}
		}
	}

	@Test
	fun verify() {
		assumeTrue("run by devtools/android-force-kill", step == "verify")
		val typed = log.readLines().filter { it.isNotBlank() }.map { line -> line.split(' ').let { it[0].toLong() to it[1].toInt() } }
		val (lastTime, lastLength) = typed.last()
		val required = typed.lastOrNull { (time, _) -> time <= lastTime - BUDGET_MILLISECONDS }?.second ?: 0
		val files = LibraryFiles(directory)
		val (body, integrity) = SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use {
			NoteStore(it).liveNotes().single().body to it.scalar("PRAGMA integrity_check")
		}
		val savedAt = typed.firstOrNull { it.second == body.length }?.first
		Log.i(TAG, "typed $lastLength, saved ${body.length}, required $required, lost ${lastLength - body.length} characters typed in the last ${savedAt?.let { lastTime - it } ?: "?"} ms before the last keystroke")

		assertEquals("ok", integrity)
		assertTrue("the saved text is a prefix of what was typed", text.startsWith(body))
		assertTrue("saved ${body.length} of the $required typed more than $BUDGET_MILLISECONDS ms before the kill", body.length >= required)
	}

	private companion object {
		const val TAG = "NativeNoteForceKill"
		const val TYPING_INTERVAL_MILLISECONDS = 25L
		const val BUDGET_MILLISECONDS = 400L
		val WORDS = listOf("note", "quartz", "ferry", "kettle", "draft", "later", "Lisbon", "bread", "idea", "sync")
	}
}
