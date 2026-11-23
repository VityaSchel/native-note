package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R

@Composable
fun LicensesScreen(onBack: () -> Unit) {
	val resources = LocalResources.current
	val paragraphs = remember(resources) { resources.assets.open("licenses.txt").bufferedReader().use { it.readText() }.trim().split("\n\n") }
	SubpageScaffold(stringResource(R.string.third_party_licenses), onBack) { padding ->
		LazyColumn(contentPadding = padding) {
			items(paragraphs) { paragraph ->
				if (paragraph.startsWith("# ")) {
					Text(
						paragraph.removePrefix("# "),
						Modifier.padding(start = 16.dp, top = 24.dp, end = 16.dp, bottom = 8.dp),
						style = MaterialTheme.typography.titleSmall,
						color = MaterialTheme.colorScheme.primary,
					)
				} else {
					Text(paragraph, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.bodyMedium)
				}
			}
		}
	}
}
