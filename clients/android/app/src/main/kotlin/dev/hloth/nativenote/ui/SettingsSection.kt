package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedListItem
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R

class SettingsRow(
	val headline: String,
	val supporting: String? = null,
	val enabled: Boolean = true,
	val announces: Boolean = false,
	val checked: Boolean? = null,
	val onClick: (() -> Unit)? = null,
)

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SubpageScaffold(title: String, onBack: () -> Unit, content: @Composable (PaddingValues) -> Unit) {
	val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
	val background = MaterialTheme.colorScheme.surfaceContainer
	Scaffold(
		modifier = Modifier.nestedScroll(scroll.nestedScrollConnection).semantics { paneTitle = title },
		containerColor = background,
		topBar = {
			LargeFlexibleTopAppBar(
				title = { Text(title, Modifier.semantics { heading() }) },
				navigationIcon = {
					IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back)) }
				},
				colors = TopAppBarDefaults.topAppBarColors(containerColor = background, scrolledContainerColor = background),
				scrollBehavior = scroll,
			)
		},
		content = content,
	)
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SettingsSection(title: String, rows: List<SettingsRow>) {
	Text(
		title,
		Modifier.padding(start = 32.dp, top = 24.dp, end = 32.dp, bottom = 8.dp).semantics { heading() },
		style = MaterialTheme.typography.titleSmall,
		color = MaterialTheme.colorScheme.primary,
	)
	Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(ListItemDefaults.SegmentedGap)) {
		rows.forEachIndexed { index, row ->
			val shapes = ListItemDefaults.segmentedShapes(index, rows.size)
			val colors = ListItemDefaults.segmentedColors(containerColor = MaterialTheme.colorScheme.surfaceBright)
			val supporting: (@Composable () -> Unit)? = row.supporting?.let { { Text(it, if (row.announces) Modifier.semantics { liveRegion = LiveRegionMode.Polite } else Modifier) } }
			val onClick = row.onClick
			if (onClick == null) {
				SegmentedListItem(shapes = shapes, colors = colors, supportingContent = supporting) { Text(row.headline) }
			} else {
				SegmentedListItem(
					onClick = onClick,
					shapes = shapes,
					verticalAlignment = Alignment.CenterVertically,
					modifier = row.checked?.let { checked -> Modifier.semantics { role = Role.Switch; toggleableState = ToggleableState(checked) } } ?: Modifier,
					colors = colors,
					enabled = row.enabled,
					supportingContent = supporting,
					trailingContent = row.checked?.let { checked -> { Switch(checked = checked, onCheckedChange = null) } },
				) { Text(row.headline) }
			}
		}
	}
}
