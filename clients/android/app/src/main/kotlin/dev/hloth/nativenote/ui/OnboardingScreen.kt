package dev.hloth.nativenote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
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
	isBiometricUnlockOn: () -> Boolean = { true },
	onFinish: () -> Unit = {},
) {
	var choosingPassword by rememberSaveable { mutableStateOf(false) }
	val password = remember { TextFieldState() }
	if (offersBiometrics) {
		BiometricOffer(password, onEnable = { onEnableBiometrics(password.text.toString()) }, isBiometricUnlockOn, onFinish)
		return
	}
	BackHandler(enabled = choosingPassword && !isWorking) { choosingPassword = false }
	if (!choosingPassword) {
		FormPage(
			pane = stringResource(R.string.welcome),
			title = stringResource(R.string.welcome_title),
			icon = R.drawable.ic_lock,
			subtitle = stringResource(R.string.welcome_subtitle),
			actions = { Button(onClick = { choosingPassword = true }) { Text(stringResource(R.string.next)) } },
		)
		return
	}

	val confirmation = remember { TextFieldState() }
	var mismatched by rememberSaveable { mutableStateOf(false) }
	val submit = {
		mismatched = password.text.toString() != confirmation.text.toString()
		if (!mismatched) onSetUp(password.text.toString())
	}
	FormPage(
		pane = stringResource(R.string.password),
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
		PasswordField(password, stringResource(R.string.password), enabled = !isWorking, imeAction = ImeAction.Next, onEdit = { mismatched = false })
		PasswordField(
			confirmation,
			stringResource(R.string.confirm_password),
			enabled = !isWorking,
			error = if (mismatched) stringResource(R.string.passwords_mismatch) else null,
			onEdit = { mismatched = false },
			onAction = { if (password.text.isNotEmpty() && !isWorking) submit() },
		)
	}
}

@Composable
private fun BiometricOffer(password: TextFieldState, onEnable: suspend () -> Failure?, isOn: () -> Boolean, onFinish: () -> Unit) {
	var working by remember { mutableStateOf(false) }
	var failure by remember { mutableStateOf<Failure?>(null) }
	var canceled by remember { mutableStateOf(false) }
	val asksForPassword = remember { password.text.isEmpty() }
	val scope = rememberCoroutineScope()
	val canEnable = password.text.isNotEmpty() && !working
	val enable = enable@{
		if (!canEnable) return@enable
		working = true
		failure = null
		canceled = false
		scope.launch {
			failure = onEnable()
			working = false
			if (failure != null) return@launch
			if (isOn()) onFinish() else canceled = true
		}
	}
	FormPage(
		pane = stringResource(R.string.biometric_unlock),
		title = stringResource(R.string.biometric_offer_title),
		icon = R.drawable.ic_fingerprint,
		subtitle = stringResource(R.string.biometric_offer_subtitle),
		actions = {
			TextButton(onClick = onFinish, enabled = !working) { Text(stringResource(R.string.not_now)) }
			Spacer(Modifier.width(8.dp))
			Button(onClick = enable, enabled = canEnable) { BusyLabel(stringResource(R.string.set_up_biometric_unlock), working) }
		},
	) {
		val problem = failure?.let { failureMessage(it) } ?: if (canceled) stringResource(R.string.biometric_not_set_up) else null
		if (asksForPassword) {
			PasswordField(
				password,
				stringResource(R.string.password),
				enabled = !working,
				error = problem,
				onEdit = {
					failure = null
					canceled = false
				},
				onAction = enable,
			)
		} else if (problem != null) {
			Text(problem, Modifier.semantics { liveRegion = LiveRegionMode.Assertive }, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
		}
	}
}
