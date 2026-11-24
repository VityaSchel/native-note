package dev.hloth.nativenote.ui

import android.graphics.Bitmap
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.autofill.ContentDataType
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncSetupUiTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val server = InstrumentationRegistry.getArguments().getString("syncServers")?.split(',')?.getOrNull(15)?.split('|')
	private var showing by mutableStateOf<AppModel?>(null)
	private var done by mutableStateOf(false)

	private fun text(id: Int) = context.getString(id)

	private fun save(name: String) {
		compose.waitForIdle()
		val renders = File(context.getExternalFilesDir(null), "renders").apply { mkdirs() }
		File(renders, "$name.png").outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
	}

	private fun phone(name: String, vararg bodies: String): AppModel {
		val model = appModel(File(folder.root, name).apply { mkdirs() })
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		for (body in bodies) model.await { createNote(body) }
		onMain { model.select(null) }
		return model
	}

	private fun show(model: AppModel) {
		done = false
		showing = model
		compose.waitForIdle()
	}

	private fun autofillType(hint: String) = compose.onNode(hasHint(hint)).fetchSemanticsNode().config[SemanticsProperties.ContentDataType]

	private fun assertWordIsClosedToAutofill(number: Int) =
		assertEquals(ContentDataType.None, autofillType(context.getString(R.string.word_number, number)))

	private fun enterServer() {
		compose.onNode(hasHint(text(R.string.server))).performTextInput(server!![0])
		compose.onNode(hasHint(text(R.string.api_key))).performTextInput(server[1])
		assertEquals(ContentDataType.Text, autofillType(text(R.string.api_key)))
		save("setup-server")
		compose.onNodeWithText(text(R.string.continue_action)).performClick()
	}

	@Test
	fun settingUpThroughTheScreensThenJoiningByPastingTheWords() {
		assumeTrue("run by devtools/android-sync-e2e", server != null)
		val first = phone("first", "Written before sync")
		val second = phone("second")
		compose.setContent {
			NativeNoteTheme {
				showing?.let { model -> key(model) { SyncSetupScreen(model, SyncSetupMode.SetUp, onDone = { done = true }) } }
			}
		}

		show(first)
		enterServer()
		compose.waitUntil(10_000) { compose.onAllNodes(hasText(text(R.string.reveal))).fetchSemanticsNodes().isNotEmpty() }
		save("setup-words-hidden")
		compose.onNodeWithText(text(R.string.reveal)).performClick()
		save("setup-words")
		val words = (1..24).associateWith { number ->
			compose.onAllNodes(hasText("$number. ", substring = true)).fetchSemanticsNodes()
				.mapNotNull { it.config.getOrNull(SemanticsProperties.Text)?.joinToString() }
				.single { it.startsWith("$number. ") }
				.removePrefix("$number. ")
		}
		compose.onNodeWithText(text(R.string.continue_action)).performClick()
		for (number in 1..24) {
			val field = compose.onAllNodes(hasHint(context.getString(R.string.word_number, number))).fetchSemanticsNodes()
			if (field.isEmpty()) continue
			assertWordIsClosedToAutofill(number)
			compose.onNode(hasHint(context.getString(R.string.word_number, number))).performTextInput(words.getValue(number))
		}
		save("setup-confirm")
		compose.onNodeWithText(text(R.string.turn_on_sync)).performClick()
		compose.waitUntil(10_000) { done }
		first.await { syncNow() }
		assertEquals(SyncStatus.Phase.Idle, onMain { first.syncStatus.phase })

		show(second)
		enterServer()
		compose.waitUntil(10_000) { compose.onAllNodes(hasText(text(R.string.enter_phrase))).fetchSemanticsNodes().isNotEmpty() }
		for (number in 1..24) assertWordIsClosedToAutofill(number)
		compose.onNode(hasHint(context.getString(R.string.word_number, 1))).performTextInput((1..24).joinToString(" ") { words.getValue(it) })
		save("setup-join")
		compose.onNodeWithText(text(R.string.turn_on_sync)).performClick()
		compose.waitUntil(10_000) { done }
		second.await { syncNow() }

		assertEquals(listOf("Written before sync"), onMain { second.notes.map { it.body } })
	}
}
