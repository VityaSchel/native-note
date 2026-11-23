package dev.hloth.nativenote.ui

import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.Failure
import kotlinx.coroutines.launch

@Composable
fun OnboardingScreen(
	hasSecureHardware: Boolean,
	isWorking: Boolean,
	onSetUp: (String) -> Unit,
	offersBiometrics: Boolean = false,
	onEnableBiometrics: suspend (String) -> Failure? = { null },
	onFinish: () -> Unit = {},
) {
	var choosingPassword by rememberSaveable { mutableStateOf(false) }
	val password = remember { TextFieldState() }
	if (offersBiometrics) {
		BiometricOffer(onEnable = { onEnableBiometrics(password.text.toString()) }, onFinish = onFinish)
		return
	}
	if (!choosingPassword) {
		FormPage(
			title = stringResource(R.string.welcome_title),
			icon = R.drawable.ic_lock,
			subtitle = stringResource(R.string.welcome_subtitle),
			actions = { Button(onClick = { choosingPassword = true }) { Text(stringResource(R.string.next)) } },
		)
		return
	}

	val confirmation = remember { TextFieldState() }
	var mismatched by rememberSaveable { mutableStateOf(false) }
	val mismatchInView = remember { BringIntoViewRequester() }
	LaunchedEffect(mismatched) { if (mismatched) mismatchInView.bringIntoView() }
	val submit = {
		mismatched = password.text.toString() != confirmation.text.toString()
		if (!mismatched) onSetUp(password.text.toString())
	}
	FormPage(
		title = stringResource(R.string.password_title),
		icon = R.drawable.ic_lock,
		subtitle = stringResource(R.string.password_subtitle),
		actions = {
			Button(onClick = submit, enabled = password.text.isNotEmpty() && !isWorking) {
				BusyLabel(stringResource(R.string.next), isWorking)
			}
		},
	) {
		if (!hasSecureHardware) {
			Text(stringResource(R.string.no_secure_hardware), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
		}
		PasswordField(password, stringResource(R.string.password), enabled = !isWorking, imeAction = ImeAction.Next)
		PasswordField(
			confirmation,
			stringResource(R.string.confirm_password),
			modifier = Modifier.bringIntoViewRequester(mismatchInView),
			enabled = !isWorking,
			error = if (mismatched) stringResource(R.string.passwords_mismatch) else null,
			imeAction = ImeAction.Done,
			onAction = { if (password.text.isNotEmpty() && !isWorking) submit() },
		)
	}
}

@Composable
private fun BiometricOffer(onEnable: suspend () -> Failure?, onFinish: () -> Unit) {
	var working by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	val scope = rememberCoroutineScope()
	FormPage(
		title = stringResource(R.string.biometric_offer_title),
		icon = R.drawable.ic_fingerprint,
		subtitle = stringResource(R.string.biometric_offer_subtitle),
		actions = {
			TextButton(onClick = onFinish, enabled = !working) { Text(stringResource(R.string.not_now)) }
			Spacer(Modifier.width(8.dp))
			Button(
				onClick = {
					working = true
					failure = null
					scope.launch {
						failure = onEnable()
						working = false
						if (failure == null) onFinish()
					}
				},
				enabled = !working,
			) { BusyLabel(stringResource(R.string.set_up_biometric_unlock), working) }
		},
	) {
		failure?.let { Text(failureMessage(it), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
	}
}
