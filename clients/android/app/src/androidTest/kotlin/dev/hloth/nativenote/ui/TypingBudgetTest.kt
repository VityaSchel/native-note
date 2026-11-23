package dev.hloth.nativenote.ui

import android.util.Log
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TypingBudgetTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val password = "correct horse battery staple"
	private var screen by mutableStateOf<@Composable () -> Unit>({})

	private fun library(name: String, count: Int): AppModel {
		val directory = File(folder.root, name).apply { mkdirs() }
		val files = LibraryFiles(directory)
		val model = appModel(directory)
		model.await { start() }
		model.await { setUp(password) }
		val now = System.currentTimeMillis()
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { connection ->
			val store = NoteStore(connection)
			connection.transaction {
				RealisticCorpus.bodies(count).forEachIndexed { index, body ->
					store.put(Note(UUID.randomUUID(), body.ifEmpty { "Note $index" }, now - index * 60_000L, now - index * 60_000L, dirty = true), pulled = false)
				}
			}
		}
		model.await { lock() }
		model.await { unlock(password) }
		onMain { model.finishOnboarding() }
		return model
	}

	private fun List<Long>.percentile(fraction: Double) = sorted()[((size - 1) * fraction).toInt()]

	@Test
	fun theModelsWorkPerKeystrokeOnAThousandNotesStaysWithinAHundredTimesTenNotes() {
		val large = library("large", 1_000)
		val small = library("small", 10)
		val timings = mapOf(large to mutableListOf<Long>(), small to mutableListOf())
		for (round in 0 until 6) {
			for ((model, samples) in timings) {
				onMain {
					val id = model.notes.first().id
					model.select(id)
					repeat(50) {
						val body = model.notes.first { it.id == id }.body + "x"
						val start = System.nanoTime()
						model.edit(id, body)
						if (round > 0) samples += System.nanoTime() - start
					}
				}
			}
		}
		val (largeTimes, smallTimes) = timings[large]!! to timings[small]!!
		Log.i(TAG, "model keystroke ns: 1,000 notes median ${largeTimes.percentile(0.5)} p95 ${largeTimes.percentile(0.95)}, 10 notes median ${smallTimes.percentile(0.5)} p95 ${smallTimes.percentile(0.95)}")

		assertTrue(largeTimes.percentile(0.5) <= 100 * maxOf(smallTimes.percentile(0.5), 1_000))
		assertTrue(largeTimes.percentile(0.95) <= 100 * maxOf(smallTimes.percentile(0.95), 1_000))
	}

	@Test
	fun aKeystrokeInTheEditorOnAThousandNotesStaysWithinItsBudget() {
		val large = library("large", 1_000)
		val small = library("small", 10)
		compose.setContent { NativeNoteTheme { Surface { key(screen) { screen() } } } }
		val variants = linkedMapOf<String, @Composable () -> Unit>(
			"plain" to { BasicTextField(remember { TextFieldState() }) },
			"10 notes" to { LibraryScreen(small, onSettings = {}) },
			"1,000 notes" to { LibraryScreen(large, onSettings = {}) },
		)
		onMain {
			large.select(large.notes.first().id)
			small.select(small.notes.first().id)
		}
		val medians = variants.keys.associateWith { Long.MAX_VALUE }.toMutableMap()
		repeat(3) {
			for ((name, content) in variants) {
				screen = content
				compose.waitForIdle()
				val field = compose.onNode(hasSetTextAction())
				repeat(5) { field.performTextInput("w") }
				compose.waitForIdle()
				val samples = List(40) {
					val start = System.nanoTime()
					field.performTextInput("x")
					compose.waitForIdle()
					System.nanoTime() - start
				}
				medians[name] = minOf(medians.getValue(name), samples.percentile(0.5))
			}
		}
		Log.i(TAG, "editor keystroke median ns: $medians")

		assertTrue("$medians", medians.getValue("1,000 notes") <= 20 * medians.getValue("plain"))
		assertTrue("$medians", medians.getValue("1,000 notes") <= 3 * medians.getValue("10 notes"))
	}

	@Test
	fun aSaveOnAThousandNotesLandsWithinAHundredMillisecondsAtThe95thPercentile() {
		val model = library("large", 1_000)
		val id = onMain { model.notes.first().id.also(model::select) }
		val samples = List(100) {
			onMain { model.edit(id, model.notes.first { it.id == id }.body + "x") }
			val start = System.nanoTime()
			runBlocking { withContext(Dispatchers.Main) { model.flushPendingSaves() } }
			System.nanoTime() - start
		}
		Log.i(TAG, "save ms: median ${samples.percentile(0.5) / 1e6} p95 ${samples.percentile(0.95) / 1e6}")

		assertTrue("p95 ${samples.percentile(0.95) / 1e6} ms", samples.percentile(0.95) <= 100_000_000)
	}

	private companion object {
		const val TAG = "NativeNoteBudgets"
	}
}
