package dev.hloth.nativenote.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import kotlinx.coroutines.awaitCancellation
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeyboardTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private var sessions = 0

	private fun text(id: Int) = context.getString(id)

	private fun field(id: Int) = compose.onNode(hasHint(text(id)))

	@OptIn(ExperimentalComposeUiApi::class)
	private fun show(content: @Composable () -> Unit) {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
		compose.setContent {
			InterceptPlatformTextInput(
				interceptor = { _, _ ->
					sessions++
					awaitCancellation()
				},
			) { NativeNoteTheme(content) }
		}
		compose.waitForIdle()
	}

	private fun assertTappingOpensTheKeyboard(node: SemanticsNodeInteraction) {
		val before = sessions
		node.performClick()
		compose.waitUntil(5_000) { sessions > before }
	}

	private fun library(): AppModel {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		return model
	}

	@Test
	fun openingTheSearchOpensTheKeyboard() {
		val model = library()
		show { LibraryScreen(model, onSettings = {}) }

		assertTappingOpensTheKeyboard(compose.onNodeWithContentDescription(text(R.string.search)))
	}

	@Test
	fun tappingTheEditorOpensTheKeyboard() {
		val model = library()
		model.await { createNote("Groceries") }
		onMain {
			model.select(null)
			model.select(model.notes.single().id)
		}
		show { LibraryScreen(model, onSettings = {}) }

		assertTappingOpensTheKeyboard(field(R.string.note))
	}

	@Test
	fun tappingEachSetupFieldOpensTheKeyboard() {
		val model = library()
		show { SyncSetupScreen(model, SyncSetupMode.SetUp, onDone = {}) }

		for (id in listOf(R.string.api_key, R.string.server)) assertTappingOpensTheKeyboard(field(id))
	}

	@Test
	fun tappingAPasswordFieldOpensTheKeyboard() {
		show { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
		compose.onNodeWithText(text(R.string.next)).performClick()

		for (id in listOf(R.string.password, R.string.confirm_password)) assertTappingOpensTheKeyboard(field(id))
	}

	@Test
	fun aNewNoteOpensTheKeyboardByItself() {
		val model = library()
		show { LibraryScreen(model, onSettings = {}) }

		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()

		compose.waitUntil(5_000) { sessions > 0 }
	}
}
