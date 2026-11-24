package dev.hloth.nativenote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.SyncStatus
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@Composable
fun NativeNoteApp(model: AppModel) {
	Surface(Modifier.fillMaxSize()) {
		val pickers = rememberLibraryPickers(model)
		when {
			model.phase == AppModel.Phase.Loading -> Unit
			model.phase == AppModel.Phase.NeedsSetup || model.isOnboarding -> Onboarding(model)
			model.phase == AppModel.Phase.Locked -> Locked(model)
			else -> Library(model, pickers)
		}
		model.failure?.let { FailureDialog(it, model::dismissFailure) }
	}
}

@Composable
private fun Onboarding(model: AppModel) {
	val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_enable_prompt_title), stringResource(R.string.cancel))
	var biometricsAnswered by rememberSaveable { mutableStateOf(false) }
	var settingUpSync by rememberSaveable { mutableStateOf(false) }
	val offersBiometrics = model.isOnboarding && model.canUseBiometrics && !biometricsAnswered
	when {
		!model.isOnboarding || offersBiometrics -> OnboardingScreen(
			model.hasSecureHardware,
			model.isOpening,
			onSetUp = { model.setUp(it) },
			offersBiometrics = offersBiometrics,
			onEnableBiometrics = { model.enableBiometricUnlock(it, prompt).await() },
			isBiometricUnlockOn = { model.isBiometricUnlockOn },
			onFinish = { biometricsAnswered = true },
		)
		settingUpSync -> SyncSetupScreen(model, SyncSetupMode.SetUp, onDone = {
			settingUpSync = false
			if (model.syncStatus.phase != SyncStatus.Phase.Off) model.finishOnboarding()
		})
		else -> FormPage(
			pane = stringResource(R.string.settings_sync),
			title = stringResource(R.string.sync_offer_title),
			icon = R.drawable.ic_sync,
			subtitle = stringResource(R.string.sync_with_a_server_explanation),
			actions = {
				TextButton(onClick = model::finishOnboarding) { Text(stringResource(R.string.not_now)) }
				Spacer(Modifier.width(8.dp))
				Button(onClick = { settingUpSync = true }) { Text(stringResource(R.string.set_up)) }
			},
		)
	}
}

@Composable
private fun Locked(model: AppModel) {
	val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_prompt_title), stringResource(R.string.use_password))
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
private fun Library(model: AppModel, pickers: LibraryPickers) {
	var showingSettings by rememberSaveable { mutableStateOf(false) }
	var showingLicenses by rememberSaveable { mutableStateOf(false) }
	var syncSetup by rememberSaveable { mutableStateOf<SyncSetupMode?>(null) }
	val prompt = rememberBiometricPrompt(stringResource(R.string.biometric_enable_prompt_title), stringResource(R.string.cancel))
	val screens = rememberSaveableStateHolder()
	LaunchedEffect(model.focusesEditor) {
		if (model.focusesEditor == null) return@LaunchedEffect
		showingSettings = false
		showingLicenses = false
	}
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
			exchange = { LibraryExchange(model, pickers) },
			sync = { SyncSettingsSection(model, onSetUp = { syncSetup = it }) },
			onLicenses = { showingLicenses = true },
		)
		return
	}
	screens.SaveableStateProvider("library") { LibraryScreen(model, onSettings = { showingSettings = true }) }
}
