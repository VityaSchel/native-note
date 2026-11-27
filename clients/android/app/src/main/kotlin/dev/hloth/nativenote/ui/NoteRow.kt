package dev.hloth.nativenote.ui

import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.storage.Note

@Composable
fun NoteRow(note: Note, grouping: NoteGrouping, selected: Boolean?, onClick: () -> Unit) {
	val lines = if (LocalDensity.current.fontScale > LARGE_TEXT) 2 else 1
	val title = @Composable { Line(note.title.take(ROW_CHARACTERS).ifEmpty { stringResource(R.string.untitled_note) }, lines) }
	val preview = @Composable { Line(note.preview(ROW_CHARACTERS).ifEmpty { stringResource(R.string.no_additional_text) }, lines) }
	val date = @Composable {
		val spoken = grouping.spokenDateLabel(note.updatedAt)
		Text(grouping.dateLabel(note.updatedAt), Modifier.semantics { contentDescription = spoken })
	}
	if (selected == null) {
		ListItem(onClick = onClick, supportingContent = preview, trailingContent = date, content = title)
	} else {
		ListItem(selected = selected, onClick = onClick, modifier = Modifier.semantics { role = Role.Button }, supportingContent = preview, trailingContent = date, content = title)
	}
}

@Composable
private fun Line(text: String, lines: Int) =
	Text(text, maxLines = lines, overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(textDirection = TextDirection.Content))

private const val ROW_CHARACTERS = 300
private const val LARGE_TEXT = 1.3f
