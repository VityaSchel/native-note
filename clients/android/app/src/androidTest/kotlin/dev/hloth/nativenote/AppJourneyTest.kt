package dev.hloth.nativenote

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.unlock.LibraryFiles
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppJourneyTest {
	@get:Rule
	val compose = createEmptyComposeRule()

	private val application = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as NativeNoteApplication

	private fun text(id: Int) = application.getString(id)

	private fun node(id: Int) = compose.onNodeWithText(text(id))

	private fun waitFor(phase: AppModel.Phase) = compose.waitUntil(20_000) { application.model.phase == phase }

	@Test
	fun setUpLeaveReturnUnlockRotateLockAndErase() {
		LibraryFiles(application.noBackupFilesDir).erase()
		val model = application.model
		compose.waitUntil(5_000) { model.phase != AppModel.Phase.Loading }
		if (model.phase != AppModel.Phase.NeedsSetup) model.start()
		waitFor(AppModel.Phase.NeedsSetup)

		ActivityScenario.launch(MainActivity::class.java).use { scenario ->
			node(R.string.next).performClick()
			node(R.string.password).performTextInput("correct horse")
			node(R.string.confirm_password).performTextInput("correct horse")
			node(R.string.next).performClick()
			waitFor(AppModel.Phase.Unlocked)
			if (model.canUseBiometrics) node(R.string.not_now).performClick()
			compose.waitUntil(5_000) { !model.isOnboarding }
			compose.onNodeWithContentDescription(text(R.string.settings)).assertIsDisplayed()

			scenario.moveToState(Lifecycle.State.CREATED)
			assertEquals(AppModel.Phase.Locked, model.phase)
			scenario.moveToState(Lifecycle.State.RESUMED)
			node(R.string.unlock).assertIsDisplayed()

			node(R.string.password).performTextInput("correct hose")
			node(R.string.unlock).performClick()
			compose.waitUntil(20_000) { model.failure != null }
			node(R.string.wrong_password).assertIsDisplayed()

			node(R.string.password).performTextInput("correct horse")
			node(R.string.unlock).performClick()
			waitFor(AppModel.Phase.Unlocked)

			scenario.recreate()
			assertEquals(AppModel.Phase.Unlocked, model.phase)
			compose.onNodeWithContentDescription(text(R.string.lock)).performClick()
			waitFor(AppModel.Phase.Locked)

			node(R.string.forgot_password).performClick()
			compose.onNode(hasText(text(R.string.erase_action)) and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
			waitFor(AppModel.Phase.NeedsSetup)
			node(R.string.welcome_title).assertIsDisplayed()
			assertEquals(emptyList<String>(), application.noBackupFilesDir.list()!!.toList())
		}
	}
}
