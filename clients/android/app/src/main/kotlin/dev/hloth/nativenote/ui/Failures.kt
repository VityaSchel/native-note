package dev.hloth.nativenote.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure

@Composable
fun failureMessage(failure: Failure): String = when (failure) {
	Failure.WrongPassword -> stringResource(R.string.wrong_password)
	Failure.WrongExportPassphrase -> stringResource(R.string.wrong_export_passphrase)
	is Failure.Unexpected -> listOfNotNull(stringResource(failure.reason), failure.detail).joinToString("\n\n")
	is Failure.Unsaved -> failureMessage(failure.reason)
}

@Composable
fun FailureDialog(failure: Failure, onDismiss: () -> Unit) {
	val (title, message) = when (failure) {
		Failure.WrongPassword, Failure.WrongExportPassphrase -> return
		is Failure.Unexpected -> stringResource(failure.title) to failureMessage(failure)
		is Failure.Unsaved -> stringResource(R.string.unsaved_title) to stringResource(R.string.unsaved_message) + "\n\n" + failureMessage(failure)
	}
	AlertDialog(
		onDismissRequest = onDismiss,
		title = { Text(title) },
		text = { Text(message) },
		confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.ok)) } },
	)
}
