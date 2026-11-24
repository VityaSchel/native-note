package dev.hloth.nativenote.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.sync.SyncError
import dev.hloth.nativenote.sync.SyncProblem
import java.io.IOException

@Composable
fun SyncStatusButton(status: SyncStatus, announced: Boolean?, onAnnounced: (Boolean?) -> Unit, onTryAgain: () -> Unit) {
	val failed = status.lastFailure
	val stopped = if (failed != null) true else if (status.problems.isNotEmpty()) false else null
	val isNews = remember(stopped) { stopped != announced }
	LaunchedEffect(stopped) { onAnnounced(stopped) }
	if (stopped == null) return
	var showing by remember { mutableStateOf(false) }
	val title = stringResource(if (stopped) R.string.sync_stopped else R.string.sync_problems)
	IconButton(
		onClick = { showing = true },
		modifier = Modifier.semantics {
			contentDescription = title
			if (isNews) liveRegion = LiveRegionMode.Polite
		},
	) {
		Icon(painterResource(R.drawable.ic_sync_problem), contentDescription = null)
	}
	if (!showing) return
	AlertDialog(
		onDismissRequest = { showing = false },
		title = { Text(title) },
		text = { DialogBody { Text(failed?.let { syncFailureMessage(it) } ?: problemMessages(status.problems)) } },
		confirmButton = {
			if (failed != null) {
				TextButton(onClick = {
					showing = false
					onTryAgain()
				}) { Text(stringResource(R.string.try_again)) }
			} else {
				TextButton(onClick = { showing = false }) { Text(stringResource(R.string.ok)) }
			}
		},
		dismissButton = if (failed != null) ({ TextButton(onClick = { showing = false }) { Text(stringResource(R.string.cancel)) } }) else null,
	)
}

@Composable
fun syncFailureMessage(error: Throwable): String = when (error) {
	is SyncError.Unopenable -> stringResource(R.string.sync_refused)
	is SyncError.Refused -> when (error.status) {
		400 -> stringResource(R.string.sync_refused)
		413 -> stringResource(R.string.sync_too_large)
		in 500..599 -> stringResource(R.string.sync_server_error, error.status)
		in 300..399 -> stringResource(R.string.sync_redirect, error.status)
		else -> stringResource(R.string.sync_invalid_response, error.status)
	}
	is SyncError.RequestMalformed -> stringResource(R.string.sync_request_malformed)
	is SyncError.Unsupported -> stringResource(R.string.sync_unsupported)
	is SyncError.ServerFault -> stringResource(R.string.sync_server_fault)
	is SyncError.ProtocolViolation -> stringResource(R.string.sync_protocol_violation)
	is IOException -> stringResource(R.string.sync_unreachable, error.message.orEmpty())
	else -> failureMessage(Failure.reason(error))
}

@Composable
fun problemMessages(problems: List<SyncProblem>): String = problems.map { problemMessage(it) }.distinct().joinToString("\n\n")

@Composable
private fun problemMessage(problem: SyncProblem): String = stringResource(
	when (problem) {
		SyncProblem.ServerBehind -> R.string.problem_server_behind
		SyncProblem.UnverifiableChange -> R.string.problem_unverifiable
		SyncProblem.NewerChange -> R.string.problem_newer
		is SyncProblem.TooLarge -> R.string.problem_too_large
		is SyncProblem.StuckConflict -> R.string.problem_stuck
	},
)
