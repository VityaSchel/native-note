package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R

@Composable
fun BusyLabel(text: String, working: Boolean) {
	val inProgress = stringResource(R.string.busy)
	Box(Modifier.semantics { if (working) stateDescription = inProgress }, contentAlignment = Alignment.Center) {
		Text(text, Modifier.alpha(if (working) 0f else 1f))
		if (working) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
	}
}
