package dev.hloth.nativenote.ui

import android.view.accessibility.AccessibilityManager
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.union
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
import androidx.compose.material3.ScaffoldDefaults
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
import androidx.compose.material3.adaptive.navigation.BackNavigationBehavior
import androidx.compose.material3.adaptive.navigation.NavigableListDetailPaneScaffold
import androidx.compose.material3.adaptive.navigation.rememberListDetailPaneScaffoldNavigator
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberSearchBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.InputMode
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalInputModeManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.traversalIndex
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.NoteGroup
import dev.hloth.nativenote.model.NoteGrouping
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.storage.Note
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
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
	var announcedSync by rememberSaveable { mutableStateOf<Boolean?>(null) }
	val accessibility = LocalContext.current.getSystemService(AccessibilityManager::class.java)
	val showsDetail = navigator.currentDestination?.pane == ListDetailPaneScaffoldRole.Detail
	val twoPane = navigator.scaffoldValue[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded &&
		navigator.scaffoldValue[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded

	val selected by remember { derivedStateOf { model.selectedNote?.id } }
	LaunchedEffect(selected) {
		val showing = navigator.currentDestination?.pane == ListDetailPaneScaffoldRole.Detail
		if (selected != null && !showing) navigator.navigateTo(ListDetailPaneScaffoldRole.Detail)
		if (selected == null && showing) navigator.navigateBack(BackNavigationBehavior.PopLatest)
	}
	LaunchedEffect(navigator) {
		snapshotFlow { navigator.currentDestination?.pane == ListDetailPaneScaffoldRole.Detail }.drop(1).filter { !it }.collect { model.select(null) }
	}
	LaunchedEffect(navigator.scaffoldValue) { navigator.seekBack(fraction = 0f) }
	LaunchedEffect(showsDetail, twoPane) {
		if (showsDetail && !twoPane) snackbar.currentSnackbarData?.takeIf { it.visuals.duration == SnackbarDuration.Indefinite }?.dismiss()
	}

	NavigableListDetailPaneScaffold(
		navigator = navigator,
		listPane = {
			AnimatedPane {
				PaneFocusSink()
				NoteList(model, grouping, twoPane, snackbar, announcedSync, onSyncAnnounced = { announcedSync = it }, onSettings)
			}
		},
		detailPane = {
			AnimatedPane {
				PaneFocusSink()
				var leaving by remember { mutableStateOf<Note?>(null) }
				val selectedNote = model.selectedNote
				SideEffect { if (selectedNote != null || twoPane) leaving = selectedNote }
				val note = selectedNote ?: leaving.takeIf { !twoPane }
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
						onEdit = { model.edit(note.id, it, shownAt = note.v) },
						onDelete = {
							val kept = model.keepForUndo(note.id)
							val deleting = model.delete(note.id)
							scope.launch {
								if (!deleting.await() || kept == null) return@launch
								snackbar.currentSnackbarData?.dismiss()
								val explores = accessibility.isTouchExplorationEnabled
								val duration = if (explores) SnackbarDuration.Indefinite else SnackbarDuration.Long
								if (snackbar.showSnackbar(deleted, undo, withDismissAction = explores, duration) == SnackbarResult.ActionPerformed) model.restore(kept)
							}
						},
						onBack = if (twoPane) null else ({ scope.launch { if (navigator.canNavigateBack(BackNavigationBehavior.PopLatest)) navigator.navigateBack(BackNavigationBehavior.PopLatest) } }),
					)
				}
			}
		},
	)
}

@Composable
private fun PaneFocusSink() {
	val inputMode = LocalInputModeManager.current
	Box(Modifier.size(1.dp).focusProperties { canFocus = inputMode.inputMode == InputMode.Touch }.clearAndSetSemantics {}.focusable())
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteList(
	model: AppModel,
	grouping: NoteGrouping,
	twoPane: Boolean,
	snackbar: SnackbarHostState,
	announcedSync: Boolean?,
	onSyncAnnounced: (Boolean?) -> Unit,
	onSettings: () -> Unit,
) {
	val results = stringResource(R.string.results)
	val groups by remember(grouping, results) { derivedStateOf { model.groups(grouping, results) } }
	val search = remember { TextFieldState(model.searchText) }
	val searchBar = rememberSearchBarState()
	val searchFocus = remember { FocusRequester() }
	val focusManager = LocalFocusManager.current
	val keyboard = LocalSoftwareKeyboardController.current
	LaunchedEffect(search) { snapshotFlow { search.text.toString() }.collect(model::updateSearch) }
	LaunchedEffect(model.searchText) { if (model.searchText.isEmpty()) search.clearText() }
	BackHandler(enabled = search.text.isNotEmpty()) {
		search.clearText()
		focusManager.clearFocus()
	}

	Scaffold(
		contentWindowInsets = ScaffoldDefaults.contentWindowInsets.union(WindowInsets.ime),
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
						modifier = Modifier.focusRequester(searchFocus),
						placeholder = { Text(stringResource(R.string.search), Modifier.clearAndSetSemantics {}) },
						leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
						trailingIcon = if (search.text.isEmpty()) null else ({
							IconButton(onClick = {
								search.clearText()
								searchFocus.requestFocus()
							}) { Icon(painterResource(R.drawable.ic_close), stringResource(R.string.clear_search)) }
						}),
					)
				},
				actions = {
					SyncStatusButton(model.syncStatus, announcedSync, onSyncAnnounced, onTryAgain = { model.syncNow() })
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
	LazyColumn(Modifier.fillMaxSize().semantics { traversalIndex = 1f }, contentPadding = contentPadding) {
		if (groups.isEmpty()) {
			item(key = "empty") {
				Box(Modifier.fillParentMaxSize(), contentAlignment = Alignment.Center) {
					Text(
						stringResource(if (model.searchText.isEmpty()) R.string.no_notes else R.string.no_results),
						Modifier.semantics { liveRegion = LiveRegionMode.Polite },
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
				NoteRow(note, grouping, selected = (note.id == model.selection).takeIf { twoPane }, onClick = { model.select(note.id) })
			}
		}
	}
}

private val FAB_CLEARANCE = 88.dp
