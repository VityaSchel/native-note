package dev.hloth.nativenote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@Composable
fun NativeNoteApp(model: AppModel) {
	Surface(Modifier.fillMaxSize()) {
		when {
			model.phase == AppModel.Phase.Loading -> Unit
			model.phase == AppModel.Phase.NeedsSetup || model.isOnboarding -> {
				val offersBiometrics = model.isOnboarding && model.canUseBiometrics
				val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_enable_prompt_title))
				OnboardingScreen(
					model.hasSecureHardware,
					model.isOpening,
					onSetUp = { model.setUp(it) },
					offersBiometrics = offersBiometrics,
					onEnableBiometrics = { model.enableBiometricUnlock(it, prompt).await() },
					onFinish = model::finishOnboarding,
				)
				LaunchedEffect(model.isOnboarding, offersBiometrics) { if (model.isOnboarding && !offersBiometrics) model.finishOnboarding() }
			}
			model.phase == AppModel.Phase.Locked -> Locked(model)
			else -> Library(model)
		}
		model.failure?.let { FailureDialog(it, model::dismissFailure) }
	}
}

@Composable
private fun Locked(model: AppModel) {
	val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_prompt_title))
	val scope = rememberCoroutineScope()
	val lifecycle = LocalLifecycleOwner.current.lifecycle
	val askBiometrics = {
		scope.launch {
			model.biometricPromptShown()
			var outcome = AppModel.BiometricOutcome.Canceled
			try {
				outcome = prompt()
			} finally {
				model.biometricPromptEnded(outcome)
			}
		}
	}
	LaunchedEffect(model.biometricOffer) {
		if (model.biometricOffer != AppModel.BiometricOffer.Prompt) return@LaunchedEffect
		lifecycle.currentStateFlow.first { it.isAtLeast(Lifecycle.State.RESUMED) }
		if (model.biometricOffer == AppModel.BiometricOffer.Prompt) askBiometrics()
	}
	UnlockScreen(
		model.failure == Failure.WrongPassword,
		model.isOpening,
		onUnlock = { model.unlock(it) },
		onErase = { model.erase() },
		biometrics = model.biometricOffer,
		onBiometrics = { askBiometrics() },
	)
}

@Composable
private fun Library(model: AppModel) {
	var showingSettings by rememberSaveable { mutableStateOf(false) }
	var showingLicenses by rememberSaveable { mutableStateOf(false) }
	var syncSetup by rememberSaveable { mutableStateOf<SyncSetupMode?>(null) }
	val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_enable_prompt_title))
	syncSetup?.let { mode ->
		SyncSetupScreen(model, mode, onDone = { syncSetup = null })
		return
	}
	if (showingLicenses) {
		BackHandler { showingLicenses = false }
		LicensesScreen(onBack = { showingLicenses = false })
		return
	}
	if (showingSettings) {
		BackHandler { showingSettings = false }
		SettingsScreen(
			onBack = { showingSettings = false },
			onChangePassword = { current, new -> model.changePassword(current, new).await() },
			biometricUnlock = model.isBiometricUnlockOn.takeIf { it || model.canUseBiometrics },
			onEnableBiometrics = { model.enableBiometricUnlock(it, prompt).await() },
			onDisableBiometrics = { model.disableBiometricUnlock().await() },
			exchange = { LibraryExchange(model) },
			sync = { SyncSettingsSection(model, onSetUp = { syncSetup = it }) },
			onLicenses = { showingLicenses = true },
		)
		return
	}
	LibraryScreen(model, onSettings = { showingSettings = true })
}
