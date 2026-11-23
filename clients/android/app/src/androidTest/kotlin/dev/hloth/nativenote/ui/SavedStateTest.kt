package dev.hloth.nativenote.ui

import android.os.Bundle
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.saveable.LocalSaveableStateRegistry
import androidx.compose.runtime.saveable.SaveableStateRegistry
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SavedStateTest {
	@get:Rule
	val compose = createComposeRule()

	@get:Rule
	val folder = TemporaryFolder()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val registry = SaveableStateRegistry(null) { true }

	private fun show(content: @Composable () -> Unit) = compose.setContent {
		CompositionLocalProvider(LocalSaveableStateRegistry provides registry) { NativeNoteTheme { content() } }
	}

	private fun field(id: Int) = compose.onNode(hasHint(context.getString(id)))

	private fun node(id: Int) = compose.onNodeWithText(context.getString(id))

	private fun assertNotSaved(secret: String) {
		compose.waitForIdle()
		val saved = compose.runOnIdle { registry.performSave() }
		assertTrue("the screen saves state, so the check is meaningful", saved.isNotEmpty())
		val flat = flatten(saved)
		assertFalse("saved state holds \"$secret\": $flat", flat.contains(secret))
	}

	private fun flatten(value: Any?): String = when (value) {
		is Map<*, *> -> value.entries.joinToString(" ") { "${flatten(it.key)}=${flatten(it.value)}" }
		is Iterable<*> -> value.joinToString(" ", "[", "]") { flatten(it) }
		is Array<*> -> value.joinToString(" ", "[", "]") { flatten(it) }
		is Bundle -> value.keySet().joinToString(" ", "{", "}") { "$it=${flatten(@Suppress("DEPRECATION") value.get(it))}" }
		else -> value.toString()
	}

	@Test
	fun theUnlockPasswordIsNeverSaved() {
		show { UnlockScreen(wrongPassword = false, isWorking = false, onUnlock = {}, onErase = {}) }

		field(R.string.password).performTextInput("unlock-secret")

		assertNotSaved("unlock-secret")
	}

	@Test
	fun theNewPasswordsAreNeverSaved() {
		show { OnboardingScreen(hasSecureHardware = true, isWorking = false, onSetUp = {}) }
		node(R.string.next).performClick()

		field(R.string.password).performTextInput("setup-secret")
		field(R.string.confirm_password).performTextInput("setup-secret")

		assertNotSaved("setup-secret")
	}

	@Test
	fun theChangePasswordFieldsAreNeverSaved() {
		show { SettingsScreen(onBack = {}, onChangePassword = { _, _ -> null }) }
		node(R.string.change_password).performClick()

		field(R.string.current_password).performTextInput("current-secret")
		field(R.string.new_password).performTextInput("new-secret")
		field(R.string.verify_password).performTextInput("verify-secret")

		assertNotSaved("current-secret")
		assertNotSaved("new-secret")
		assertNotSaved("verify-secret")
	}

	@Test
	fun noteTextAndTheSearchAreNeverSaved() {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		model.await { createNote() }
		onMain { model.edit(model.selection!!, "Diary\nnote-secret") }
		onMain { model.select(null) }
		show { LibraryScreen(model, onSettings = {}) }

		compose.onNode(hasSetTextAction()).performTextInput("query-secret")
		assertNotSaved("query-secret")

		onMain { model.updateSearch("") }
		compose.waitUntil(10_000) { compose.onAllNodes(hasText("Diary")).fetchSemanticsNodes().isNotEmpty() }
		compose.onNodeWithText("Diary").performClick()
		compose.waitUntil(10_000) { model.selection != null }
		compose.onNode(hasSetTextAction()).performTextInput("typed-secret ")
		assertNotSaved("note-secret")
		assertNotSaved("typed-secret")
		onMain { model.lock() }
	}
}
