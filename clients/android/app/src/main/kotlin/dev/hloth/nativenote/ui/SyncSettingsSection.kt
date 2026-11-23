package dev.hloth.nativenote.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.SyncStatus
import kotlinx.coroutines.launch

@Composable
fun SyncSettingsSection(model: AppModel, onSetUp: (SyncSetupMode) -> Unit) {
	val status = model.syncStatus
	val scope = rememberCoroutineScope()
	var confirmingTurnOff by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	Text(
		stringResource(R.string.settings_sync),
		Modifier.padding(start = 16.dp, top = 24.dp, end = 16.dp, bottom = 8.dp),
		style = MaterialTheme.typography.titleSmall,
		color = MaterialTheme.colorScheme.primary,
	)
	if (status.phase == SyncStatus.Phase.Off) {
		ListItem(onClick = { onSetUp(SyncSetupMode.SetUp) }, supportingContent = { Text(stringResource(R.string.sync_with_a_server_explanation)) }) {
			Text(stringResource(R.string.sync_with_a_server))
		}
		return
	}
	val lastSynced = status.lastSynced?.let {
		if (System.currentTimeMillis() - it < DateUtils.MINUTE_IN_MILLIS) {
			stringResource(R.string.last_synced_just_now)
		} else {
			stringResource(R.string.last_synced, DateUtils.getRelativeTimeSpanString(it).toString())
		}
	}
	ListItem(supportingContent = { Text(listOfNotNull(status.server, lastSynced).joinToString("\n")) }) { Text(stringResource(R.string.server)) }
	ListItem(onClick = { model.syncNow() }, enabled = status.phase != SyncStatus.Phase.Syncing) { Text(stringResource(R.string.sync_now)) }
	ListItem(onClick = { onSetUp(SyncSetupMode.Rotate) }) { Text(stringResource(R.string.change_recovery_phrase_row)) }
	ListItem(onClick = { onSetUp(SyncSetupMode.ChangeServer) }) { Text(stringResource(R.string.change_server_row)) }
	ListItem(onClick = { confirmingTurnOff = true }) { Text(stringResource(R.string.turn_off_sync_row)) }
	if (confirmingTurnOff) {
		AlertDialog(
			onDismissRequest = { confirmingTurnOff = false },
			title = { Text(stringResource(R.string.turn_off_sync_title)) },
			text = { Text(stringResource(R.string.turn_off_sync_message)) },
			confirmButton = {
				TextButton(onClick = {
					confirmingTurnOff = false
					scope.launch { failure = model.turnOffSync() }
				}) { Text(stringResource(R.string.turn_off_sync)) }
			},
			dismissButton = { TextButton(onClick = { confirmingTurnOff = false }) { Text(stringResource(R.string.cancel)) } },
		)
	}
	failure?.let { FailureDialog(it) { failure = null } }
}
