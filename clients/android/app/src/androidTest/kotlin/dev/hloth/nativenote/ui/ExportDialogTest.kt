package dev.hloth.nativenote.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.support.WithoutKeyboard
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
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

	private fun dialogField(id: Int) = compose.onNode(hasHint(text(id)) and hasAnyAncestor(isDialog()))

	private fun setContent(content: @Composable () -> Unit) = compose.setContent { WithoutKeyboard(content) }

	@Test
	fun anEncryptedExportNeedsTheSamePassphraseTwiceAndCancelExportsNothing() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		setContent { NativeNoteTheme { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, exchange = { LibraryExchange(model) }) } }

		compose.onNodeWithText(text(R.string.export_notes)).performClick()
		dialogNode(R.string.export_explanation).assertIsDisplayed()
		val encrypts = compose.onNode(isToggleable() and hasText(text(R.string.encrypt_with_passphrase)) and hasAnyAncestor(isDialog()))
		val export = compose.onNode(hasText(text(R.string.export_action)) and hasClickAction())
		encrypts.assertIsOn()
		assertEquals(Role.Checkbox, encrypts.fetchSemanticsNode().config[SemanticsProperties.Role])
		export.assertIsNotEnabled()
		encrypts.performClick()
		encrypts.assertIsOff()
		export.assertIsEnabled()
		encrypts.performClick()

		dialogField(R.string.passphrase).performTextInput("export passphrase")
		dialogField(R.string.verify_passphrase).performTextInput("export passphrase!")
		compose.onNode(hasText(text(R.string.export_action)) and hasClickAction()).performClick()
		dialogNode(R.string.passphrases_mismatch).assertIsDisplayed()
		compose.onNode(hasScrollAction() and !hasSetTextAction() and hasAnyAncestor(isDialog())).assertExists()

		compose.onNode(hasText(text(R.string.cancel)) and hasAnyAncestor(isDialog())).performClick()
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
		assertFalse(runBlocking { onMain { model.exportLibrary { error("nothing was chosen to export") } }.await() })
	}

	@Test
	fun turningEncryptionBackOnLeavesTheFocusOnTheCheckbox() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		setContent { NativeNoteTheme { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }, exchange = { LibraryExchange(model) }) } }
		compose.onNodeWithText(text(R.string.export_notes)).performClick()
		compose.waitUntil(5_000) { dialogField(R.string.passphrase).fetchSemanticsNode().config[SemanticsProperties.Focused] }

		val encrypts = compose.onNode(isToggleable() and hasText(text(R.string.encrypt_with_passphrase)) and hasAnyAncestor(isDialog()))
		encrypts.performClick()
		encrypts.performClick()

		encrypts.assertIsOn()
		dialogField(R.string.passphrase).assertIsNotFocused()
	}

	@Test
	fun lockingClosesTheExportDialogForGood() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		setContent { NativeNoteTheme { NativeNoteApp(model) } }
		compose.onNodeWithContentDescription(text(R.string.settings)).performClick()
		compose.onNodeWithText(text(R.string.export_notes)).performClick()
		dialogField(R.string.passphrase).performTextInput("export passphrase")

		model.await { lock() }
		compose.waitForIdle()
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)

		model.await { unlock("correct horse") }
		compose.waitForIdle()
		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
	}

	@Test
	fun theResultIsShownAndDismissed() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		setContent { NativeNoteTheme { NativeNoteApp(model) } }
		onMain { model.prepareExport(null) }
		runBlocking { onMain { model.exportLibrary { } }.await() }

		dialogNode(R.string.ok).assertIsDisplayed()
		compose.onNode(hasText(context.resources.getQuantityString(R.plurals.exported_notes, 0, 0)) and hasAnyAncestor(isDialog())).assertIsDisplayed()
		dialogNode(R.string.ok).performClick()

		assertEquals(0, compose.onAllNodes(isDialog()).fetchSemanticsNodes().size)
	}
}
