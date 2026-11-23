package dev.hloth.nativenote.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryScreenTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private fun text(id: Int) = context.getString(id)

	private fun unlocked(vararg bodies: String): AppModel {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp("correct horse") }
		onMain { model.finishOnboarding() }
		for (body in bodies) {
			model.await { createNote() }
			onMain { model.edit(model.selection!!, body) }
		}
		onMain { model.select(null) }
		return model
	}

	private fun show(model: AppModel) = compose.setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }

	private fun waitFor(condition: () -> Boolean) = compose.waitUntil(10_000, condition)

	private fun count(text: String) = compose.onAllNodes(hasText(text)).fetchSemanticsNodes().size

	@Test
	fun theSearchFieldTakesFocusOnlyWhenTapped() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
		show(unlocked("Groceries"))
		compose.waitForIdle()

		compose.onNode(hasSetTextAction()).assertIsNotFocused()
		compose.onNodeWithText("Groceries").performClick()
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		compose.waitForIdle()
		compose.onNode(hasSetTextAction()).assertIsNotFocused()

		compose.onNode(hasSetTextAction()).performClick()
		compose.onNode(hasSetTextAction()).assertIsFocused()
	}

	@Test
	fun aKeyboardStartsAtTheSearchField() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(false)
		show(unlocked("Groceries"))
		compose.waitForIdle()

		compose.onNode(hasSetTextAction()).assertIsFocused()
	}

	@Test
	fun aNewNoteOpensTheEditorAndItsTitleListsAfterGoingBack() {
		val model = unlocked()
		show(model)
		compose.onNodeWithText(text(R.string.no_notes)).assertIsDisplayed()

		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()
		waitFor { model.selection != null }
		compose.onNode(hasSetTextAction()).performTextInput("Groceries\nmilk and eggs")
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()

		waitFor { model.selection == null }
		compose.onNodeWithText("Groceries").assertIsDisplayed()
		compose.onNodeWithText(text(R.string.today)).assertIsDisplayed()
		assertEquals("Groceries\nmilk and eggs", model.notes.single().body)
	}

	@Test
	fun leavingANewNoteEmptyRemovesItFromTheList() {
		val model = unlocked()
		show(model)

		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()
		waitFor { model.selection != null }
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()

		waitFor { model.notes.isEmpty() }
		compose.onNodeWithText(text(R.string.no_notes)).assertIsDisplayed()
	}

	@Test
	fun searchingNarrowsTheListAndSaysWhenNothingMatches() {
		val model = unlocked("Trip\nkayak and tent", "Groceries\nmilk")
		show(model)
		compose.onNodeWithText("Groceries").assertIsDisplayed()

		compose.onNode(hasSetTextAction()).performTextInput("kayak")
		waitFor { count("Groceries") == 0 }
		compose.onNodeWithText("Trip").assertIsDisplayed()
		compose.onNodeWithText(text(R.string.results)).assertIsDisplayed()

		compose.onNode(hasSetTextAction()).performTextInput(" absent")
		waitFor { count(text(R.string.no_results)) == 1 }

		compose.onNodeWithContentDescription(text(R.string.clear_search)).performClick()
		waitFor { count("Groceries") == 1 }
		compose.onNodeWithText("Trip").assertIsDisplayed()
	}

	@Test
	fun deletingFromTheEditorReturnsToTheListWithoutTheNote() {
		val model = unlocked("Doomed\ntext", "Kept\ntext")
		show(model)

		compose.onNodeWithText("Doomed").performClick()
		waitFor { model.selection != null }
		compose.onNodeWithContentDescription(text(R.string.delete)).performClick()

		waitFor { model.notes.size == 1 }
		compose.onNodeWithText("Kept").assertIsDisplayed()
		assertEquals(0, count("Doomed"))
		assertNull(model.selection)
	}

	@Test
	fun deletingOffersAnUndoThatBringsTheNoteBack() {
		val model = unlocked("Doomed\ntext")
		show(model)

		compose.onNodeWithText("Doomed").performClick()
		waitFor { model.selection != null }
		compose.onNodeWithContentDescription(text(R.string.delete)).performClick()
		waitFor { model.notes.isEmpty() }
		compose.onNodeWithText(text(R.string.undo)).performClick()

		waitFor { model.notes.size == 1 }
		assertEquals("Doomed\ntext", model.notes.single().body)
	}

	@Test
	fun theLockButtonLocksTheLibrary() {
		val model = unlocked("Secret\ntext")
		show(model)

		compose.onNodeWithContentDescription(text(R.string.lock)).performClick()

		waitFor { model.phase == AppModel.Phase.Locked }
		assertEquals(emptyList<Any>(), model.notes)
	}
}
