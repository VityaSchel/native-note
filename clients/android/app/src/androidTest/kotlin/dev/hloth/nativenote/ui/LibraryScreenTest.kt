package dev.hloth.nativenote.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.DeviceConfigurationOverride
import androidx.compose.ui.test.ForcedSize
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.WindowSize
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.assertIsNotFocused
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToIndexAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isFocused
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.rightClick
import androidx.compose.ui.test.then
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.WithoutKeyboard
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.hasHint
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.support.pressBack
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
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

	private var focusManager: FocusManager? = null
	private var size by mutableStateOf(DpSize.Unspecified)

	private fun show(model: AppModel) = compose.setContent {
		focusManager = LocalFocusManager.current
		WithoutKeyboard {
			if (size == DpSize.Unspecified) {
				NativeNoteTheme { LibraryScreen(model, onSettings = {}) }
			} else {
				DeviceConfigurationOverride(DeviceConfigurationOverride.ForcedSize(size) then DeviceConfigurationOverride.WindowSize(size)) {
					NativeNoteTheme { LibraryScreen(model, onSettings = {}) }
				}
			}
		}
	}

	private fun <T> disk(read: (NoteStore) -> T): T = LibraryFiles(folder.root).let { files ->
		SQLiteConnection(files.database, UnlockKeys.databaseKey("correct horse", files.record.read()!!), create = false).use { read(NoteStore(it)) }
	}

	private val editor get() = compose.onNode(hasHint(text(R.string.note)))
	private val searchField get() = compose.onNode(hasHint(text(R.string.search)))

	private fun isSearching() = compose.onAllNodes(hasHint(text(R.string.search))).fetchSemanticsNodes().isNotEmpty()

	private fun leaveSearchWithBack() {
		compose.waitForIdle()
		pressBack()
		waitFor { !isSearching() }
	}

	private fun openSearch() = compose.onNodeWithContentDescription(text(R.string.search)).performClick()
	private val newNote get() = compose.onNodeWithContentDescription(text(R.string.new_note))
	private val back get() = compose.onNodeWithContentDescription(text(R.string.back))

	private fun click(node: SemanticsNodeInteraction) = node.fetchSemanticsNode().config[SemanticsActions.OnClick].action!!

	private fun text(id: Int, quantity: Int) = InstrumentationRegistry.getInstrumentation().targetContext.resources.getQuantityString(id, quantity, quantity)

	private fun waitFor(condition: () -> Boolean) = compose.waitUntil(10_000, condition)

	private fun count(text: String) = compose.onAllNodes(hasText(text)).fetchSemanticsNodes().size

	@Test
	fun theSearchFieldOpensFocusedOnlyWhenAskedFor() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
		show(unlocked("Groceries"))
		compose.onNodeWithText(text(R.string.app_name)).assertIsDisplayed()
		searchField.assertDoesNotExist()

		compose.onNodeWithText("Groceries").performClick()
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		compose.waitForIdle()
		searchField.assertDoesNotExist()

		openSearch()
		searchField.assertIsFocused()
		newNote.assertDoesNotExist()
		compose.onNodeWithContentDescription(text(R.string.settings)).assertDoesNotExist()

		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		searchField.assertDoesNotExist()
		newNote.assertIsDisplayed()

		openSearch()
		compose.onNodeWithText("Groceries").performClick()
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		compose.waitForIdle()
		searchField.assertDoesNotExist()
		newNote.assertIsDisplayed()
	}

	@Test
	fun holdingANoteOffersDeleteWithUndo() {
		val model = unlocked("Groceries", "Kayak")
		show(model)
		compose.onNodeWithText(text(R.plurals.notes_count, 2)).assertIsDisplayed()

		compose.onNodeWithText("Groceries").performTouchInput { longClick() }
		compose.onNodeWithText(text(R.string.delete)).performClick()

		waitFor { count("Groceries") == 0 }
		assertEquals(null, onMain { model.selection })
		compose.onNodeWithText(text(R.plurals.notes_count, 1)).assertIsDisplayed()
		waitFor { count(text(R.string.undo)) == 1 }
		compose.onNodeWithText(text(R.string.undo)).performClick()
		waitFor { onMain { model.notes.size } == 2 }
		compose.waitForIdle()
		assertEquals(null, onMain { model.selection })
		compose.onNode(hasHint(text(R.string.note))).assertDoesNotExist()
		compose.onNodeWithText(text(R.plurals.notes_count, 2)).assertIsDisplayed()
	}

	@Test
	fun aRightClickOpensTheSameMenuWithoutOpeningTheNote() {
		val model = unlocked("Groceries")
		show(model)

		compose.onNodeWithText("Groceries").performMouseInput { rightClick() }

		compose.onNodeWithText(text(R.string.delete)).assertIsDisplayed()
		assertEquals(null, onMain { model.selection })
	}

	@Test
	fun holdingIsOfferedToScreenReadersAsShowingActions() {
		show(unlocked("Groceries"))

		val row = compose.onNode(hasText("Groceries") and hasClickAction()).fetchSemanticsNode().config
		assertEquals(text(R.string.note_actions), row[SemanticsActions.OnLongClick].label)
	}

	@Test
	fun aNoteRowIsAButtonNotARadioButton() {
		show(unlocked("Groceries"))

		val row = compose.onNodeWithText("Groceries").fetchSemanticsNode().config
		assertFalse(SemanticsProperties.Selected in row)
		assertFalse(SemanticsProperties.ToggleableState in row)
		assertNotEquals(Role.RadioButton, row.getOrNull(SemanticsProperties.Role))
	}

	@Test
	fun theFocusSinkIsInvisibleToAccessibility() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
		show(unlocked("Groceries"))
		compose.waitForIdle()

		assertEquals(0, compose.onAllNodes(isFocused()).fetchSemanticsNodes().size)
	}

	@Test
	fun aNoteSelectedBeforeTheScreenAppearsOpens() {
		val model = unlocked("Groceries\nmilk")
		onMain { model.select(model.notes.single().id) }
		show(model)

		compose.onNode(hasHint(text(R.string.note))).assertIsDisplayed()
		assertNotNull(onMain { model.selection })
	}

	@Test
	fun openingANoteLeavesTheKeyboardDownAndANewNoteTakesIt() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(true)
		show(unlocked("Groceries"))
		compose.onNodeWithText("Groceries").performClick()
		compose.waitForIdle()
		compose.onNode(hasHint(text(R.string.note))).assertIsNotFocused()

		compose.onNodeWithContentDescription(text(R.string.back)).performClick()
		compose.onNodeWithContentDescription(text(R.string.new_note)).performClick()
		compose.waitUntil(10_000) { compose.onAllNodes(hasHint(text(R.string.note)) and isFocused()).fetchSemanticsNodes().size == 1 }
	}

	@Test
	fun backLeavesTheSearchBeforeTheApp() {
		val model = unlocked("Groceries", "Kayak")
		show(model)
		openSearch()
		searchField.performTextInput("kayak")
		waitFor { count("Groceries") == 0 }

		leaveSearchWithBack()
		waitFor { count("Groceries") == 1 }
		compose.onNodeWithText("Kayak").assertIsDisplayed()

		openSearch()
		searchField.assertIsDisplayed()
		leaveSearchWithBack()
		newNote.assertIsDisplayed()
	}

	@Test
	fun noResultsIsAnnouncedAndClearingReturnsToTheField() {
		show(unlocked("Groceries"))
		openSearch()
		searchField.performTextInput("kayak")
		waitFor { count(text(R.string.no_results)) == 1 }
		assertEquals(LiveRegionMode.Polite, compose.onNodeWithText(text(R.string.no_results)).fetchSemanticsNode().config[SemanticsProperties.LiveRegion])

		compose.runOnIdle { focusManager!!.clearFocus(force = true) }
		searchField.assertIsNotFocused()
		compose.onNodeWithContentDescription(text(R.string.clear_search)).performClick()
		searchField.assertIsFocused()
	}

	@Test
	fun theListComesAfterItsActionsForScreenReaders() {
		show(unlocked("Groceries"))

		assertEquals(1f, compose.onNode(hasScrollToIndexAction()).fetchSemanticsNode().config[SemanticsProperties.TraversalIndex])
	}

	@Test
	fun undoAfterTwoDeletesBringsBackTheSecond() {
		val model = unlocked("First", "Second")
		show(model)
		for (title in listOf("First", "Second")) {
			compose.onNodeWithText(title).performClick()
			waitFor { model.selection != null }
			compose.onNodeWithContentDescription(text(R.string.delete)).performClick()
			waitFor { model.selection == null && model.notes.none { it.title == title } }
		}
		waitFor { disk { it.liveNotes() }.isEmpty() }
		waitFor { count(text(R.string.undo)) == 1 }
		compose.mainClock.advanceTimeBy(1_000)
		compose.waitForIdle()
		compose.onNodeWithText(text(R.string.undo)).performClick()

		waitFor { model.notes.size == 1 }
		assertEquals("Second", model.notes.single().title)
	}

	@Test
	fun thePanesFollowTheWindowWhenItIsRotatedOrUnfolded() {
		size = PORTRAIT
		val model = unlocked("Groceries\nmilk", "Kayak\nrental")
		show(model)
		compose.onNodeWithText("Groceries").performClick()
		waitFor { compose.onAllNodes(hasHint(text(R.string.note))).fetchSemanticsNodes().size == 1 }
		newNote.assertIsNotDisplayed()

		size = LANDSCAPE
		compose.waitForIdle()
		newNote.assertIsDisplayed()
		editor.assertIsDisplayed()
		back.assertDoesNotExist()

		size = PORTRAIT
		compose.waitForIdle()
		newNote.assertIsNotDisplayed()
		editor.assertIsDisplayed()
		back.assertIsDisplayed()

		size = LANDSCAPE
		compose.waitForIdle()
		onMain { model.select(null) }
		compose.waitForIdle()
		size = PORTRAIT
		compose.waitForIdle()
		newNote.assertIsDisplayed()
		editor.assertIsNotDisplayed()
		assertEquals(0, count(text(R.string.no_note_selected)))
	}

	@Test
	fun pressingBackTwiceReturnsToTheListOnce() {
		size = PORTRAIT
		val model = unlocked("Groceries")
		show(model)
		compose.onNodeWithText("Groceries").performClick()
		waitFor { compose.onAllNodes(hasHint(text(R.string.note))).fetchSemanticsNodes().size == 1 }
		compose.waitForIdle()

		val goBack = click(back)
		onMain {
			goBack()
			goBack()
		}
		compose.waitForIdle()

		newNote.assertIsDisplayed()
		editor.assertIsNotDisplayed()
	}

	@Test
	fun openingAnotherNoteDuringTheSlideFinishesIt() {
		size = PORTRAIT
		val model = unlocked("Groceries", "Kayak")
		val (first, second) = onMain { model.notes.map { it.id } }
		show(model)
		onMain { model.select(first) }
		compose.waitForIdle()
		val atRest = back.fetchSemanticsNode().boundsInRoot.left
		onMain { model.select(null) }
		compose.waitForIdle()
		compose.mainClock.autoAdvance = false

		onMain { model.select(first) }
		compose.mainClock.advanceTimeBy(150)
		onMain { model.select(second) }
		compose.mainClock.advanceTimeBy(100)
		compose.mainClock.autoAdvance = true
		compose.waitForIdle()

		newNote.assertIsNotDisplayed()
		assertEquals(back.fetchSemanticsNode().boundsInRoot.left, atRest, 1f)
		editor.assertIsDisplayed()
		editor.assertTextContains(onMain { model.selectedNote!!.body })
	}

	@Test
	fun deletingNeverFlashesThePlaceholder() {
		size = PORTRAIT
		val model = unlocked("Groceries")
		show(model)
		compose.onNodeWithText("Groceries").performClick()
		waitFor { compose.onAllNodes(hasHint(text(R.string.note))).fetchSemanticsNodes().size == 1 }
		compose.waitForIdle()
		val delete = click(compose.onNodeWithContentDescription(text(R.string.delete)))
		compose.mainClock.autoAdvance = false

		onMain { delete() }
		repeat(40) {
			compose.mainClock.advanceTimeByFrame()
			assertEquals("frame $it", 0, count(text(R.string.no_note_selected)))
		}
		compose.mainClock.autoAdvance = true
		newNote.assertIsDisplayed()
	}

	@Test
	fun aHebrewNoteRunsRightToLeft() {
		val model = unlocked("\u05E9\u05DC\u05D5\u05DD")
		onMain { model.select(model.notes.single().id) }
		show(model)

		val layouts = mutableListOf<TextLayoutResult>()
		compose.onNode(hasHint(text(R.string.note))).performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
		assertEquals(ResolvedTextDirection.Rtl, layouts.single().getParagraphDirection(0))
	}

	@Test
	fun aKeyboardStartsSomewhereWithoutOpeningTheSearch() {
		InstrumentationRegistry.getInstrumentation().setInTouchMode(false)
		show(unlocked("Groceries"))
		compose.waitForIdle()

		assertEquals(1, compose.onAllNodes(isFocused()).fetchSemanticsNodes().size)
		searchField.assertDoesNotExist()
	}

	@Test
	fun aSearchInProgressIsStillOpenAfterUnlocking() {
		val model = unlocked("Groceries", "Kayak")
		onMain { model.updateSearch("kayak") }
		show(model)

		searchField.assertIsDisplayed()
		searchField.assertIsNotFocused()
		waitFor { count("Groceries") == 0 }
	}

	@Test
	fun aNewNoteFromElsewhereLeavesTheSearch() {
		val model = unlocked("Groceries")
		show(model)
		openSearch()
		searchField.performTextInput("gro")
		waitFor { model.searchText == "gro" }

		model.await { createNote() }
		waitFor { compose.onAllNodes(hasHint(text(R.string.note))).fetchSemanticsNodes().size == 1 }
		compose.onNodeWithContentDescription(text(R.string.back)).performClick()

		compose.waitForIdle()
		searchField.assertDoesNotExist()
		newNote.assertIsDisplayed()
	}

	@Test
	fun aNewNoteBesideTheSearchLeavesIt() {
		val model = unlocked("Groceries")
		size = DpSize(1000.dp, 800.dp)
		show(model)
		openSearch()

		model.await { createNote() }

		waitFor { !isSearching() }
		newNote.assertIsDisplayed()
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

		openSearch()
		searchField.performTextInput("kayak")
		waitFor { count("Groceries") == 0 }
		compose.onNodeWithText("Trip").assertIsDisplayed()
		compose.onNodeWithText(text(R.string.results)).assertIsDisplayed()

		searchField.performTextInput(" absent")
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
		waitFor { model.notes.isEmpty() && count(text(R.string.undo)) == 1 }
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

	private companion object {
		val PORTRAIT = DpSize(411.dp, 800.dp)
		val LANDSCAPE = DpSize(914.dp, 500.dp)
	}
}
