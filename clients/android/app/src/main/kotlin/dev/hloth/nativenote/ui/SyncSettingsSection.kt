package dev.hloth.nativenote.ui

import android.text.format.DateUtils
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
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
	val title = stringResource(R.string.settings_sync)
	if (status.phase == SyncStatus.Phase.Off) {
		SettingsSection(title, listOf(
			SettingsRow(stringResource(R.string.sync_with_a_server), stringResource(R.string.sync_with_a_server_explanation), onClick = { onSetUp(SyncSetupMode.SetUp) }),
		))
		return
	}
	val lastSynced = status.lastSynced?.let {
		if (System.currentTimeMillis() - it < DateUtils.MINUTE_IN_MILLIS) {
			stringResource(R.string.last_synced_just_now)
		} else {
			stringResource(R.string.last_synced, DateUtils.getRelativeTimeSpanString(it).toString())
		}
	}
	SettingsSection(title, listOf(
		SettingsRow(stringResource(R.string.server), listOfNotNull(status.server, lastSynced).joinToString("\n")),
		SettingsRow(stringResource(R.string.sync_now), enabled = status.phase != SyncStatus.Phase.Syncing, onClick = { model.syncNow() }),
		SettingsRow(stringResource(R.string.change_recovery_phrase_row), onClick = { onSetUp(SyncSetupMode.Rotate) }),
		SettingsRow(stringResource(R.string.change_server_row), onClick = { onSetUp(SyncSetupMode.ChangeServer) }),
		SettingsRow(stringResource(R.string.turn_off_sync_row), onClick = { confirmingTurnOff = true }),
	))
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
