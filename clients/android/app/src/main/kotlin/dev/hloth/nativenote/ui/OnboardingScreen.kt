package dev.hloth.nativenote.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
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
		OnboardingPage(
			title = stringResource(R.string.welcome_title),
			subtitle = stringResource(R.string.welcome_subtitle),
			action = { Button(onClick = { choosingPassword = true }) { Text(stringResource(R.string.next)) } },
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
	OnboardingPage(
		title = stringResource(R.string.password_title),
		subtitle = stringResource(R.string.password_subtitle),
		action = {
			Button(onClick = submit, enabled = password.text.isNotEmpty() && !isWorking) {
				BusyLabel(stringResource(R.string.next), isWorking)
			}
		},
	) {
		if (!hasSecureHardware) {
			Text(stringResource(R.string.no_secure_hardware), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
		}
		PasswordField(password, stringResource(R.string.password), isNew = true, enabled = !isWorking, imeAction = ImeAction.Next)
		PasswordField(
			confirmation,
			stringResource(R.string.confirm_password),
			modifier = Modifier.bringIntoViewRequester(mismatchInView),
			isNew = true,
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
	OnboardingPage(
		title = stringResource(R.string.biometric_offer_title),
		subtitle = stringResource(R.string.biometric_offer_subtitle),
		icon = R.drawable.ic_fingerprint,
		action = {
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

@Composable
private fun OnboardingPage(
	title: String,
	subtitle: String,
	icon: Int = R.drawable.ic_lock,
	action: @Composable () -> Unit,
	content: @Composable ColumnScope.() -> Unit = {},
) {
	Box(Modifier.fillMaxSize().safeDrawingPadding().imePadding(), contentAlignment = Alignment.TopCenter) {
		Column(Modifier.widthIn(max = 560.dp).fillMaxSize().padding(24.dp)) {
			Column(
				Modifier.weight(1f).verticalScroll(rememberScrollState()),
				verticalArrangement = Arrangement.spacedBy(16.dp),
			) {
				Icon(painterResource(icon), contentDescription = null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.primary)
				Text(title, style = MaterialTheme.typography.headlineMedium)
				Text(subtitle, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
				Spacer(Modifier.size(8.dp))
				content()
			}
			Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.End) { action() }
		}
	}
}
