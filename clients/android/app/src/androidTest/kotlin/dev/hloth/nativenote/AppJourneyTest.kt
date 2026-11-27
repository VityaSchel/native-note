package dev.hloth.nativenote

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.unlock.LibraryFiles
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
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
	private fun field(id: Int) = compose.onNode(hasHint(text(id)))
	private fun press(id: Int) = node(id).assertIsEnabled().performSemanticsAction(SemanticsActions.OnClick)

	private fun waitFor(phase: AppModel.Phase) = compose.waitUntil(20_000) { application.model.phase == phase }

	@Test
	fun setUpLeaveReturnUnlockRotateLockAndErase() {
		LibraryFiles(application.noBackupFilesDir).erase()
		val model = application.model
		compose.waitUntil(5_000) { model.phase != AppModel.Phase.Loading }
		if (model.phase != AppModel.Phase.NeedsSetup) model.start()
		waitFor(AppModel.Phase.NeedsSetup)

		ActivityScenario.launch(MainActivity::class.java).use { scenario ->
			press(R.string.next)
			field(R.string.password).performTextInput("correct horse")
			field(R.string.confirm_password).performTextInput("correct horse")
			press(R.string.next)
			waitFor(AppModel.Phase.Unlocked)
			if (model.canUseBiometrics) press(R.string.not_now)
			node(R.string.sync_offer_title).assertIsDisplayed()
			press(R.string.set_up)
			compose.waitUntil(5_000) { field(R.string.server).fetchSemanticsNode().config[SemanticsProperties.Focused] }
			compose.onNodeWithContentDescription(text(R.string.back)).performClick()
			press(R.string.not_now)
			compose.waitUntil(5_000) { !model.isOnboarding }
			compose.onNodeWithContentDescription(text(R.string.settings)).performClick()
			node(R.string.export_notes).performClick()
			var window = 0
			scenario.onActivity { window = it.window.decorView.width }
			val margin = (24 * application.resources.displayMetrics.density).toInt()
			val dialog = compose.onNode(isDialog()).fetchSemanticsNode().size.width
			assertTrue("dialog $dialog px in a $window px window", dialog <= window - 2 * margin)
			compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick()
			compose.onNodeWithContentDescription(text(R.string.back)).performClick()
			compose.onNodeWithContentDescription(text(R.string.settings)).assertIsDisplayed()

			scenario.moveToState(Lifecycle.State.CREATED)
			assertEquals(AppModel.Phase.Locked, model.phase)
			scenario.moveToState(Lifecycle.State.RESUMED)
			node(R.string.unlock).assertIsDisplayed()

			field(R.string.password).performTextInput("correct hose")
			press(R.string.unlock)
			compose.waitUntil(20_000) { model.failure != null }
			node(R.string.wrong_password).assertIsDisplayed()

			field(R.string.password).performTextInput("correct horse")
			press(R.string.unlock)
			waitFor(AppModel.Phase.Unlocked)

			scenario.recreate()
			assertEquals(AppModel.Phase.Unlocked, model.phase)
			compose.onNodeWithContentDescription(text(R.string.lock)).performClick()
			waitFor(AppModel.Phase.Locked)

			press(R.string.forgot_password)
			compose.onNode(hasText(text(R.string.erase_action)) and hasClickAction() and hasAnyAncestor(isDialog())).performClick()
			waitFor(AppModel.Phase.NeedsSetup)
			node(R.string.welcome_title).assertIsDisplayed()
			assertEquals(emptyList<String>(), application.noBackupFilesDir.list()!!.toList())
		}
	}
}
