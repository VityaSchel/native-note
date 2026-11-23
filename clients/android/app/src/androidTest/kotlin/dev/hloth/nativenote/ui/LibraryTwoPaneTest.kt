package dev.hloth.nativenote.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
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
import dev.hloth.nativenote.support.onMain
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryTwoPaneTest {
	@get:Rule
	val folder = TemporaryFolder()

	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private fun text(id: Int) = context.getString(id)

	private fun count(text: String) = compose.onAllNodes(hasText(text)).fetchSemanticsNodes().size

	@Before
	fun onlyOnAnExpandedWindow() = assumeTrue("needs a window at least 840 dp wide", context.resources.configuration.screenWidthDp >= 840)

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

	@Test
	fun theListStaysBesideTheEditorAndSelectionMovesBetweenNotes() {
		val model = unlocked("Alpha\nfirst", "Beta\nsecond")
		compose.setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }
		compose.onNodeWithText(text(R.string.no_note_selected)).assertIsDisplayed()

		compose.onNodeWithText("Alpha").performClick()
		compose.waitUntil(10_000) { model.selection != null }
		compose.onNodeWithText("Beta").assertIsDisplayed()
		assertEquals(0, compose.onAllNodes(hasContentDescription(text(R.string.back))).fetchSemanticsNodes().size)

		compose.onNodeWithText("Beta").performClick()
		compose.waitUntil(10_000) { model.selectedNote?.title == "Beta" }
		compose.onNodeWithText("Alpha").assertIsDisplayed()

		compose.onNodeWithContentDescription(text(R.string.delete)).performClick()
		compose.waitUntil(10_000) { model.notes.size == 1 }
		compose.onNodeWithText(text(R.string.no_note_selected)).assertIsDisplayed()
		compose.onNodeWithText("Alpha").assertIsDisplayed()
		assertEquals(0, count("Beta"))
	}

	@Test
	fun leavingAnEmptyNewNoteForAnotherNoteDiscardsIt() {
		val model = unlocked("Alpha\nfirst")
		compose.setContent { NativeNoteTheme { LibraryScreen(model, onSettings = {}) } }

		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()
		compose.waitUntil(10_000) { model.notes.size == 2 }
		assertEquals("", model.selectedNote?.body)
		compose.onNodeWithText("Alpha").performClick()

		compose.waitUntil(10_000) { model.notes.size == 1 }
		assertEquals("Alpha", model.selectedNote?.title)
	}
}
