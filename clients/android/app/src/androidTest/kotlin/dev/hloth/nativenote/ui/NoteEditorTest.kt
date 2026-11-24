package dev.hloth.nativenote.ui

import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.AnnotatedString
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.storage.Note
import java.util.UUID
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NoteEditorTest {
	@get:Rule
	val compose = createComposeRule()

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
}
