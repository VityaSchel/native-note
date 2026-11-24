package dev.hloth.nativenote.ui

import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.storage.Note

@Composable
fun NoteRow(note: Note, grouping: NoteGrouping, selected: Boolean, onClick: () -> Unit) {
	val title = note.title.ifEmpty { stringResource(R.string.untitled_note) }
	val preview = note.preview().ifEmpty { stringResource(R.string.no_additional_text) }
	val date = grouping.dateLabel(note.updatedAt)
	val spoken = "${grouping.spokenDateLabel(note.updatedAt)}, $preview"
	ListItem(
		selected = selected,
		onClick = onClick,
		supportingContent = {
			Text(
				buildAnnotatedString {
					withStyle(SpanStyle(color = MaterialTheme.colorScheme.onSurface)) { append(date) }
					append("  ")
					append(preview)
				},
				Modifier.semantics { contentDescription = spoken },
				maxLines = 1,
				overflow = TextOverflow.Ellipsis,
			)
		},
	) {
		Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis)
	}
}
