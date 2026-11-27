package dev.hloth.nativenote.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
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
	var requested by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	val title = stringResource(R.string.settings_sync)
	if (status.phase == SyncStatus.Phase.Off) {
		SettingsSection(title, listOf(
			SettingsRow(stringResource(R.string.sync_with_a_server), stringResource(R.string.sync_with_a_server_explanation), onClick = { onSetUp(SyncSetupMode.SetUp) }),
		))
		return
	}
	SettingsSection(title, listOf(
		SettingsRow(stringResource(R.string.server), status.server),
		SettingsRow(stringResource(R.string.sync_now), syncOutcome(status), enabled = status.phase != SyncStatus.Phase.Syncing, announces = requested, onClick = {
			requested = true
			model.syncNow()
		}),
		SettingsRow(stringResource(R.string.change_recovery_phrase), onClick = { onSetUp(SyncSetupMode.Rotate) }),
		SettingsRow(stringResource(R.string.change_server), onClick = { onSetUp(SyncSetupMode.ChangeServer) }),
		SettingsRow(stringResource(R.string.turn_off_sync), onClick = { confirmingTurnOff = true }),
	))
	if (confirmingTurnOff) {
		AlertDialog(
			onDismissRequest = { confirmingTurnOff = false },
			modifier = Modifier.widthIn(max = maxDialogWidth()),
			title = { Text(stringResource(R.string.turn_off_sync_title)) },
			text = { DialogBody { Text(stringResource(R.string.turn_off_sync_message)) } },
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

@Composable
private fun syncOutcome(status: SyncStatus): String {
	val failure = status.lastFailure
	val lastSynced = status.lastSynced
	val outcome = when {
		status.phase == SyncStatus.Phase.Syncing -> stringResource(R.string.syncing)
		failure != null -> "${stringResource(R.string.sync_stopped)}. ${syncFailureMessage(failure)}"
		lastSynced == null -> stringResource(R.string.not_synced_yet)
		System.currentTimeMillis() - lastSynced < DateUtils.MINUTE_IN_MILLIS -> stringResource(R.string.last_synced_just_now)
		else -> stringResource(R.string.last_synced, DateUtils.getRelativeTimeSpanString(lastSynced).toString())
	}
	return if (failure != null || status.problems.isEmpty()) outcome else "$outcome\n\n${problemMessages(status.problems)}"
}
