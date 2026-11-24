package dev.hloth.nativenote.ui

import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDirection
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.storage.Note

@Composable
fun NoteRow(note: Note, grouping: NoteGrouping, selected: Boolean?, onClick: () -> Unit) {
	val title = note.title.take(ROW_CHARACTERS).ifEmpty { stringResource(R.string.untitled_note) }
	val preview = note.preview(ROW_CHARACTERS).ifEmpty { stringResource(R.string.no_additional_text) }
	val date = grouping.dateLabel(note.updatedAt)
	val spoken = "${grouping.spokenDateLabel(note.updatedAt)}, $preview"
	val lines = if (LocalDensity.current.fontScale > LARGE_TEXT) 2 else 1
	val headline = @Composable {
		Text(title, maxLines = lines, overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(textDirection = TextDirection.Content))
	}
	val supporting = @Composable {
		Text(
			buildAnnotatedString {
				withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurface)) { append(date) }
				append("  ")
				append(FIRST_STRONG_ISOLATE)
				append(preview)
				append(POP_DIRECTIONAL_ISOLATE)
			},
			Modifier.semantics { contentDescription = spoken },
			maxLines = lines,
			overflow = TextOverflow.Ellipsis,
		)
	}
	if (selected == null) {
		ListItem(onClick = onClick, supportingContent = supporting) { headline() }
	} else {
		ListItem(selected = selected, onClick = onClick, modifier = Modifier.semantics { role = Role.Button }, supportingContent = supporting) { headline() }
	}
}

private const val ROW_CHARACTERS = 300
private const val LARGE_TEXT = 1.3f
private const val FIRST_STRONG_ISOLATE = '\u2068'
private const val POP_DIRECTIONAL_ISOLATE = '\u2069'
