package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.selectAll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel

@Composable
fun UnlockScreen(
	wrongPassword: Boolean,
	isWorking: Boolean,
	onUnlock: (String) -> Unit,
	onErase: () -> Unit,
	biometrics: AppModel.BiometricOffer = AppModel.BiometricOffer.Hidden,
	onBiometrics: () -> Unit = {},
) {
	val password = remember { TextFieldState() }
	val focus = remember { FocusRequester() }
	val haptics = LocalHapticFeedback.current
	var confirmingErase by rememberSaveable { mutableStateOf(false) }
	val submit = { if (password.text.isNotEmpty() && !isWorking) onUnlock(password.text.toString()) }

	LaunchedEffect(Unit) { focus.requestFocus() }
	LaunchedEffect(wrongPassword) {
		if (!wrongPassword) return@LaunchedEffect
		haptics.performHapticFeedback(HapticFeedbackType.Reject)
		password.edit { selectAll() }
		focus.requestFocus()
	}

	FormPage(
		title = stringResource(R.string.app_name),
		icon = R.drawable.ic_lock,
		actions = {
			TextButton(onClick = { confirmingErase = true }, enabled = !isWorking) { Text(stringResource(R.string.forgot_password)) }
			Spacer(Modifier.weight(1f))
			Button(onClick = submit, enabled = password.text.isNotEmpty() && !isWorking) { BusyLabel(stringResource(R.string.unlock), isWorking) }
		},
	) {
		PasswordField(
			password,
			stringResource(R.string.password),
			modifier = Modifier.focusRequester(focus),
			enabled = !isWorking,
			error = if (wrongPassword) stringResource(R.string.wrong_password) else null,
			imeAction = ImeAction.Go,
			onAction = submit,
		)
		if (biometrics != AppModel.BiometricOffer.Hidden) {
			OutlinedButton(onClick = onBiometrics, enabled = biometrics == AppModel.BiometricOffer.Button && !isWorking) {
				Icon(painterResource(R.drawable.ic_fingerprint), contentDescription = null, Modifier.size(18.dp))
				Spacer(Modifier.width(8.dp))
				Text(stringResource(R.string.unlock_with_biometrics))
			}
		}
	}

	if (confirmingErase) {
		AlertDialog(
			onDismissRequest = { confirmingErase = false },
			title = { Text(stringResource(R.string.erase_title)) },
			text = { Text(stringResource(R.string.erase_message)) },
			confirmButton = {
				TextButton(onClick = {
					confirmingErase = false
					onErase()
				}) { Text(stringResource(R.string.erase_action), color = MaterialTheme.colorScheme.error) }
			},
			dismissButton = { TextButton(onClick = { confirmingErase = false }) { Text(stringResource(R.string.cancel)) } },
		)
	}
}
