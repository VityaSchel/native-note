package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
	onBack: () -> Unit,
	onChangePassword: suspend (String, String) -> Failure?,
	biometricUnlock: Boolean? = null,
	onEnableBiometrics: suspend (String) -> Failure? = { null },
	onDisableBiometrics: suspend () -> Failure? = { null },
	exchange: @Composable () -> Unit = {},
	sync: @Composable () -> Unit = {},
	onLicenses: () -> Unit = {},
) {
	var changingPassword by rememberSaveable { mutableStateOf(false) }
	var enablingBiometrics by rememberSaveable { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	val scope = rememberCoroutineScope()
	Scaffold(
		topBar = {
			TopAppBar(
				title = { Text(stringResource(R.string.settings)) },
				navigationIcon = {
					IconButton(onClick = onBack) { Icon(painterResource(R.drawable.ic_arrow_back), stringResource(R.string.back)) }
				},
			)
		},
	) { padding ->
		Column(Modifier.padding(padding).verticalScroll(rememberScrollState())) {
			Text(
				stringResource(R.string.settings_unlock),
				Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 8.dp),
				style = MaterialTheme.typography.titleSmall,
				color = MaterialTheme.colorScheme.primary,
			)
			ListItem(
				onClick = { changingPassword = true },
				supportingContent = { Text(stringResource(R.string.password_subtitle)) },
			) { Text(stringResource(R.string.change_password)) }
			if (biometricUnlock != null) {
				ListItem(
					onClick = { if (biometricUnlock) scope.launch { failure = onDisableBiometrics() } else enablingBiometrics = true },
					supportingContent = { Text(stringResource(R.string.biometric_unlock_explanation)) },
					trailingContent = { Switch(checked = biometricUnlock, onCheckedChange = null) },
				) { Text(stringResource(R.string.biometric_unlock)) }
			}
			sync()
			Text(
				stringResource(R.string.settings_notes),
				Modifier.padding(start = 16.dp, top = 24.dp, end = 16.dp, bottom = 8.dp),
				style = MaterialTheme.typography.titleSmall,
				color = MaterialTheme.colorScheme.primary,
			)
			exchange()
			Text(
				stringResource(R.string.settings_about),
				Modifier.padding(start = 16.dp, top = 24.dp, end = 16.dp, bottom = 8.dp),
				style = MaterialTheme.typography.titleSmall,
				color = MaterialTheme.colorScheme.primary,
			)
			ListItem(onClick = onLicenses) { Text(stringResource(R.string.third_party_licenses)) }
		}
	}
	if (changingPassword) ChangePasswordDialog(onDismiss = { changingPassword = false }, onChangePassword)
	if (enablingBiometrics) EnableBiometricsDialog(onDismiss = { enablingBiometrics = false }, onEnableBiometrics)
	failure?.let { FailureDialog(it) { failure = null } }
}

@Composable
private fun EnableBiometricsDialog(onDismiss: () -> Unit, onEnable: suspend (String) -> Failure?) {
	val password = remember { TextFieldState() }
	var working by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	val scope = rememberCoroutineScope()
	val canSubmit = password.text.isNotEmpty() && !working
	val submit = submit@{
		if (!canSubmit) return@submit
		working = true
		failure = null
		scope.launch {
			failure = onEnable(password.text.toString())
			working = false
			if (failure == null) onDismiss()
		}
	}
	AlertDialog(
		onDismissRequest = { if (!working) onDismiss() },
		title = { Text(stringResource(R.string.biometric_enable_prompt_title)) },
		text = {
			Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(stringResource(R.string.biometric_enable_explanation))
				PasswordField(password, stringResource(R.string.password), enabled = !working, error = failure?.let { failureMessage(it) }, onAction = submit)
			}
		},
		confirmButton = {
			TextButton(onClick = submit, enabled = canSubmit) { BusyLabel(stringResource(R.string.turn_on), working) }
		},
		dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text(stringResource(R.string.cancel)) } },
	)
}

@Composable
private fun ChangePasswordDialog(onDismiss: () -> Unit, onChangePassword: suspend (String, String) -> Failure?) {
	val current = remember { TextFieldState() }
	val new = remember { TextFieldState() }
	val verify = remember { TextFieldState() }
	var working by remember { mutableStateOf(false) }
	var mismatched by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	val scope = rememberCoroutineScope()
	val canSubmit = current.text.isNotEmpty() && new.text.isNotEmpty() && !working
	val submit = submit@{
		if (!canSubmit) return@submit
		mismatched = new.text.toString() != verify.text.toString()
		if (mismatched) return@submit
		working = true
		failure = null
		scope.launch {
			failure = onChangePassword(current.text.toString(), new.text.toString())
			working = false
			if (failure == null) onDismiss()
		}
	}
	AlertDialog(
		onDismissRequest = { if (!working) onDismiss() },
		title = { Text(stringResource(R.string.change_password)) },
		text = {
			Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(stringResource(R.string.change_password_explanation))
				PasswordField(current, stringResource(R.string.current_password), enabled = !working, error = failure?.let { failureMessage(it) }, imeAction = ImeAction.Next)
				PasswordField(new, stringResource(R.string.new_password), isNew = true, enabled = !working, imeAction = ImeAction.Next)
				PasswordField(
					verify,
					stringResource(R.string.verify_password),
					isNew = true,
					enabled = !working,
					error = if (mismatched) stringResource(R.string.new_passwords_mismatch) else null,
					onAction = submit,
				)
			}
		},
		confirmButton = {
			TextButton(onClick = submit, enabled = canSubmit) {
				BusyLabel(stringResource(R.string.change_password), working)
			}
		},
		dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text(stringResource(R.string.cancel)) } },
	)
}
