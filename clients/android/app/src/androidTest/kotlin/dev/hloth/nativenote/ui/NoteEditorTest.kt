package dev.hloth.nativenote.ui

import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.withKeyDown
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.storage.Note
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NoteEditorTest {
	@get:Rule
	val compose = createComposeRule()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext

	private var note by mutableStateOf(Note(UUID.randomUUID(), "", 0, 0))

	@Test
	fun aKeyPressedWhileTheLastOneComesBackIsKeptAndAPulledTextReplacesBoth() {
		val editor = compose.onNode(hasSetTextAction())
		var insert: ((AnnotatedString) -> Boolean)? = null
		var pressed = false
		compose.setContent {
			NativeNoteTheme {
				NoteEditor(note, rememberGrouping(), takesFocus = false, onFocused = {}, onEdit = { note = note.copy(body = it) }, onDelete = {}, onBack = null)
			}
			val shown = note.body
			SideEffect {
				if (shown != "a" || pressed) return@SideEffect
				pressed = true
				insert!!(AnnotatedString("b"))
			}
		}
		insert = editor.fetchSemanticsNode().config[SemanticsActions.InsertTextAtCursor].action

		editor.performTextInput("a")
		compose.waitForIdle()
		assertTrue(pressed)
		editor.assertTextContains("ab")

		compose.runOnIdle { note = note.copy(body = "pulled") }
		editor.assertTextContains("pulled")
	}

	@Test
	fun undoAfterAPullNeverBringsBackTheTextFromBeforeIt() {
		val editor = compose.onNode(hasSetTextAction())
		compose.setContent {
			NativeNoteTheme {
				NoteEditor(note, rememberGrouping(), takesFocus = false, onFocused = {}, onEdit = { note = note.copy(body = it) }, onDelete = {}, onBack = null)
			}
		}
		editor.performTextInput("typed here")
		compose.runOnIdle { note = note.copy(body = "pulled from another device") }
		editor.assertTextEquals("pulled from another device")

		editor.performKeyInput { withKeyDown(Key.CtrlLeft) { pressKey(Key.Z) } }

		compose.waitForIdle()
		editor.assertTextEquals("pulled from another device")
		assertEquals("pulled from another device", note.body)
	}

	@Test
	fun undoAndRedoStepThroughTheTyping() {
		val editor = compose.onNode(hasSetTextAction())
		compose.setContent {
			NativeNoteTheme {
				NoteEditor(note, rememberGrouping(), takesFocus = false, onFocused = {}, onEdit = { note = note.copy(body = it) }, onDelete = {}, onBack = null)
			}
		}
		val undo = compose.onNodeWithContentDescription(context.getString(R.string.undo))
		val redo = compose.onNodeWithContentDescription(context.getString(R.string.redo))
		undo.assertIsNotEnabled()
		redo.assertIsNotEnabled()

		editor.performTextInput("Groceries")
		undo.performClick()
		editor.assertTextEquals("")
		compose.runOnIdle { assertEquals("", note.body) }

		redo.performClick()
		editor.assertTextEquals("Groceries")
		compose.runOnIdle { assertEquals("Groceries", note.body) }
		redo.assertIsNotEnabled()
	}
}
