package dev.hloth.nativenote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.material3.AppBarWithSearch
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SearchBarDefaults
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.NoteGroup
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.model.SyncStatus
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun LibraryScreen(model: AppModel, onSettings: () -> Unit) {
	val navigator = rememberListDetailPaneScaffoldNavigator<String>()
	val scope = rememberCoroutineScope()
	val grouping = rememberGrouping()
	val snackbar = remember { SnackbarHostState() }
	val deleted = stringResource(R.string.note_deleted)
	val undo = stringResource(R.string.undo)
	val showsDetail = navigator.currentDestination?.pane == ListDetailPaneScaffoldRole.Detail
	val twoPane = navigator.scaffoldValue[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded &&
		navigator.scaffoldValue[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded

	LaunchedEffect(model.selection) {
		val showing = navigator.currentDestination?.pane == ListDetailPaneScaffoldRole.Detail
		if (model.selection != null && !showing) navigator.navigateTo(ListDetailPaneScaffoldRole.Detail)
		if (model.selection == null && showing) navigator.navigateBack()
	}
	LaunchedEffect(showsDetail) { if (!showsDetail) model.select(null) }

	NavigableListDetailPaneScaffold(
		navigator = navigator,
		listPane = {
			AnimatedPane {
				PaneFocusSink()
				NoteList(model, grouping, twoPane, snackbar, onSettings)
			}
		},
		detailPane = {
			AnimatedPane {
				val note = model.selectedNote
				if (note == null) {
					Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
						Text(stringResource(R.string.no_note_selected), color = MaterialTheme.colorScheme.onSurfaceVariant)
					}
				} else {
					NoteEditor(
						note,
						grouping,
						takesFocus = model.focusesEditor == note.id,
						onFocused = model::editorTookFocus,
						onEdit = { model.edit(note.id, it) },
						onDelete = {
							val kept = model.keepForUndo(note.id)
							val deleting = model.delete(note.id)
							scope.launch {
								if (!deleting.await() || kept == null) return@launch
								if (snackbar.showSnackbar(deleted, undo, duration = SnackbarDuration.Long) == SnackbarResult.ActionPerformed) model.restore(kept)
							}
						},
						onBack = if (twoPane) null else ({ scope.launch { navigator.navigateBack() } }),
					)
				}
			}
		},
	)
}

@Composable
private fun PaneFocusSink() {
	val inputMode = LocalInputModeManager.current
	Box(Modifier.size(1.dp).focusProperties { canFocus = inputMode.inputMode == InputMode.Touch }.focusable().clearAndSetSemantics {})
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteList(model: AppModel, grouping: NoteGrouping, twoPane: Boolean, snackbar: SnackbarHostState, onSettings: () -> Unit) {
	val results = stringResource(R.string.results)
	val groups by remember(grouping, results) { derivedStateOf { model.groups(grouping, results) } }
	val search = remember { TextFieldState(model.searchText) }
	val searchBar = rememberSearchBarState()
	val keyboard = LocalSoftwareKeyboardController.current
	LaunchedEffect(search) { snapshotFlow { search.text.toString() }.collect(model::updateSearch) }

	Scaffold(
		containerColor = MaterialTheme.colorScheme.surface,
		snackbarHost = { SnackbarHost(snackbar) },
		topBar = {
			AppBarWithSearch(
				state = searchBar,
				inputField = {
					SearchBarDefaults.InputField(
						textFieldState = search,
						searchBarState = searchBar,
						onSearch = { keyboard?.hide() },
						placeholder = { Text(stringResource(R.string.search)) },
						leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
						trailingIcon = if (search.text.isEmpty()) null else ({
							IconButton(onClick = { search.clearText() }) { Icon(painterResource(R.drawable.ic_close), stringResource(R.string.clear_search)) }
						}),
					)
				},
				actions = {
					SyncStatusButton(model.syncStatus, onTryAgain = { model.syncNow() })
					IconButton(onClick = { model.lock() }) { Icon(painterResource(R.drawable.ic_lock), stringResource(R.string.lock)) }
					IconButton(onClick = onSettings) { Icon(painterResource(R.drawable.ic_settings), stringResource(R.string.settings)) }
				},
			)
		},
		floatingActionButton = {
			FloatingActionButton(onClick = { model.createNote() }) { Icon(painterResource(R.drawable.ic_add), stringResource(R.string.new_note)) }
		},
	) { padding ->
		val direction = LocalLayoutDirection.current
		val syncs = model.syncStatus.phase != SyncStatus.Phase.Off
		PullToRefreshBox(
			isRefreshing = model.syncStatus.phase == SyncStatus.Phase.Syncing,
			onRefresh = { model.syncNow() },
			modifier = Modifier.padding(top = padding.calculateTopPadding()),
			enabled = syncs,
		) {
			NoteRows(model, grouping, twoPane, groups, PaddingValues(
				start = padding.calculateStartPadding(direction),
				end = padding.calculateEndPadding(direction),
				bottom = padding.calculateBottomPadding() + FAB_CLEARANCE,
			))
		}
	}
}

@Composable
private fun NoteRows(model: AppModel, grouping: NoteGrouping, twoPane: Boolean, groups: List<NoteGroup>, contentPadding: PaddingValues) {
	LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
		if (groups.isEmpty()) {
			item(key = "empty") {
				Box(Modifier.fillParentMaxSize(), contentAlignment = Alignment.Center) {
					Text(
						stringResource(if (model.searchText.isEmpty()) R.string.no_notes else R.string.no_results),
						style = MaterialTheme.typography.titleMedium,
						color = MaterialTheme.colorScheme.onSurfaceVariant,
					)
				}
			}
		}
		for (group in groups) {
			stickyHeader(key = "group ${group.title}", contentType = "header") {
				Text(
					group.title,
					Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surface).padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
					style = MaterialTheme.typography.titleSmall,
					color = MaterialTheme.colorScheme.primary,
				)
			}
			items(group.notes, key = { it.id }, contentType = { "note" }) { note ->
				NoteRow(note, grouping, selected = twoPane && note.id == model.selection, onClick = { model.select(note.id) })
			}
		}
	}
}

private val FAB_CLEARANCE = 88.dp
