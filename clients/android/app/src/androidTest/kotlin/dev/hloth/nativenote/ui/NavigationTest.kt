package dev.hloth.nativenote.ui

import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.support.WithoutKeyboard
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NavigationTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private lateinit var model: AppModel

	private fun text(id: Int) = InstrumentationRegistry.getInstrumentation().targetContext.getString(id)

	private fun node(id: Int) = compose.onNodeWithText(text(id))
	private fun button(id: Int) = compose.onNodeWithContentDescription(text(id))

	private fun show() {
		model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		compose.setContent {
			WithoutKeyboard {
				DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(DpSize(400.dp, 500.dp))) {
					NativeNoteTheme { NativeNoteApp(model) }
				}
			}
		}
	}

	@After
	fun lock() {
		onMain { model.lock() }
	}

	@Test
	fun settingsKeepsItsPlaceUnderAPageOfItsOwnAndOpensFromTheTop() {
		show()
		button(R.string.settings).performClick()
		node(R.string.third_party_licenses).performScrollTo().performClick()
		button(R.string.back).performClick()
		node(R.string.third_party_licenses).assertIsDisplayed()

		button(R.string.back).performClick()
		button(R.string.settings).performClick()
		node(R.string.change_password).assertIsDisplayed()
	}

	@Test
	fun aDialogLeftForANewNoteStaysClosed() {
		show()
		button(R.string.settings).performClick()
		node(R.string.change_password).performClick()
		compose.onNode(isDialog()).assertExists()

		model.await { createNote() }
		compose.onNode(hasHint(text(R.string.note))).assertIsDisplayed()
		button(R.string.back).performClick()
		button(R.string.settings).performClick()

		compose.waitForIdle()
		compose.onNode(isDialog()).assertDoesNotExist()
	}

	@Test
	fun aNoteCreatedDuringSyncSetupShowsWhenItCloses() {
		show()
		button(R.string.settings).performClick()
		node(R.string.sync_with_a_server).performScrollTo().performClick()
		compose.onNode(hasHint(text(R.string.server))).assertExists()

		model.await { createNote() }
		compose.onNode(hasHint(text(R.string.server))).assertExists()
		button(R.string.back).performClick()

		compose.onNode(hasHint(text(R.string.note))).assertIsDisplayed()
	}
}
