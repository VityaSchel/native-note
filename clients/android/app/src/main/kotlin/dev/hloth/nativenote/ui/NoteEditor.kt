package dev.hloth.nativenote.ui

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.hintText
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.traversalIndex
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.storage.Note

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteEditor(
	note: Note,
	grouping: NoteGrouping,
	takesFocus: Boolean,
	onFocused: () -> Unit,
	onEdit: (String) -> Unit,
	onDelete: () -> Unit,
	onBack: (() -> Unit)?,
) {
	key(note.id) {
		val scroll = rememberScrollState()
		val bar = TopAppBarDefaults.pinnedScrollBehavior(scroll)
		val text = remember { TextFieldState(note.body) }
		Scaffold(
			topBar = {
				TopAppBar(
					title = {},
					navigationIcon = {
						if (onBack != null) {
							IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back)) }
						}
					},
					actions = {
						IconButton(onClick = text.undoState::undo, enabled = text.undoState.canUndo) { Icon(painterResource(R.drawable.ic_undo), stringResource(R.string.undo)) }
						IconButton(onClick = text.undoState::redo, enabled = text.undoState.canRedo) { Icon(painterResource(R.drawable.ic_redo), stringResource(R.string.redo)) }
						IconButton(onClick = onDelete) { Icon(painterResource(R.drawable.ic_delete), stringResource(R.string.delete)) }
					},
					scrollBehavior = bar,
				)
			},
		) { padding ->
			EditorText(note, text, grouping, takesFocus, onFocused, onEdit, scroll, Modifier.padding(padding).consumeWindowInsets(padding).imePadding())
		}
	}
}

@Composable
private fun EditorText(
	note: Note,
	text: TextFieldState,
	grouping: NoteGrouping,
	takesFocus: Boolean,
	onFocused: () -> Unit,
	onEdit: (String) -> Unit,
	scroll: ScrollState,
	modifier: Modifier,
) {
	val focus = remember { FocusRequester() }
	val edit by rememberUpdatedState(onEdit)
	val titleStyle = MaterialTheme.typography.titleLarge.toSpanStyle().copy(fontWeight = FontWeight.Bold)
	val title = remember(titleStyle) { TitleLine(titleStyle) }
	var dateHeight by remember { mutableIntStateOf(0) }
	val spokenDate = grouping.spokenEditorDateLine(note.updatedAt)
	val name = stringResource(R.string.note)
	val sent = remember { ArrayDeque<String>() }

	LaunchedEffect(text) {
		snapshotFlow { text.text.toString() }.collect {
			sent += it
			edit(it)
		}
	}
	LaunchedEffect(note.body) {
		val echoed = sent.indexOf(note.body)
		if (echoed >= 0) {
			repeat(echoed) { sent.removeFirst() }
		} else if (text.text.toString() != note.body) {
			sent.clear()
			text.setTextAndPlaceCursorAtEnd(note.body)
			text.undoState.clearHistory()
		}
	}
	TakeFocus(focus, takesFocus, onFocused)

	BoxWithConstraints(modifier.fillMaxSize()) {
		val fieldHeight = maxHeight - with(LocalDensity.current) { dateHeight.toDp() }
		Column(Modifier.fillMaxSize().verticalScroll(scroll)) {
			Text(
				grouping.editorDateLine(note.updatedAt),
				Modifier.fillMaxWidth().onSizeChanged { dateHeight = it.height }.padding(top = 4.dp).semantics { contentDescription = spokenDate },
				style = MaterialTheme.typography.labelMedium,
				color = MaterialTheme.colorScheme.onSurfaceVariant,
				textAlign = TextAlign.Center,
			)
			BasicTextField(
				text,
				Modifier.fillMaxWidth().heightIn(min = fieldHeight).focusRequester(focus).semantics {
					hintText = name
					traversalIndex = -1f
				}.padding(horizontal = 16.dp, vertical = 12.dp),
				textStyle = MaterialTheme.typography.bodyLarge.copy(color = MaterialTheme.colorScheme.onSurface, textDirection = TextDirection.Content),
				keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences),
				cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
				outputTransformation = title,
			)
		}
	}
}

private class TitleLine(private val style: SpanStyle) : OutputTransformation {
	override fun TextFieldBuffer.transformOutput() {
		val text = asCharSequence()
		val end = text.indexOfFirst { it == '\n' || it == '\r' }.let { if (it < 0) text.length else it }
		if (end > 0) addStyle(style, 0, end)
	}
}
