package dev.hloth.nativenote.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ExportDialogTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private fun text(id: Int) = context.getString(id)

	private fun dialogNode(id: Int) = compose.onNode(hasText(text(id)) and hasAnyAncestor(isDialog()))

	@Test
	fun anEncryptedExportNeedsTheSamePassphraseTwiceAndCancelExportsNothing() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		compose.setContent { NativeNoteTheme { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, exchange = { LibraryExchange(model) }) } }

		compose.onNodeWithText(text(R.string.export_notes)).performClick()
		dialogNode(R.string.export_explanation).assertIsDisplayed()
		compose.onNode(isToggleable() and hasAnyAncestor(isDialog())).performClick()
		compose.onNode(hasText(text(R.string.export_action)) and hasClickAction()).assertIsNotEnabled()

		dialogNode(R.string.passphrase).performTextInput("export passphrase")
		dialogNode(R.string.verify_passphrase).performTextInput("export passphrase!")
		compose.onNode(hasText(text(R.string.export_action)) and hasClickAction()).performClick()
		dialogNode(R.string.passphrases_mismatch).assertIsDisplayed()

		compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick()
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
		assertFalse(runBlocking { onMain { model.exportLibrary { error("nothing was chosen to export") } }.await() })
	}
}
