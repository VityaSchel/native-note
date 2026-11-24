package dev.hloth.nativenote.ui

import android.app.Activity
import android.hardware.biometrics.BiometricManager.Authenticators
import android.hardware.biometrics.BiometricPrompt
import android.os.CancellationSignal
import androidx.activity.compose.LocalActivity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import dev.hloth.nativenote.model.AppModel.BiometricOutcome
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

@Composable
fun rememberBiometricPrompt(title: String, cancel: String): suspend () -> BiometricOutcome {
	val activity = LocalActivity.current
	return remember(activity, title, cancel) {
		{ activity?.let { authenticate(it, title, cancel) } ?: BiometricOutcome.Unavailable }
	}
}

private suspend fun authenticate(activity: Activity, title: String, cancel: String): BiometricOutcome = suspendCancellableCoroutine { continuation ->
	val signal = CancellationSignal()
	continuation.invokeOnCancellation { signal.cancel() }
	val finish = { outcome: BiometricOutcome -> if (continuation.isActive) continuation.resume(outcome) }
	val prompt = BiometricPrompt.Builder(activity)
		.setTitle(title)
		.setAllowedAuthenticators(Authenticators.BIOMETRIC_STRONG)
		.setNegativeButton(cancel, activity.mainExecutor) { _, _ -> finish(BiometricOutcome.Canceled) }
		.setConfirmationRequired(false)
		.build()
	prompt.authenticate(
		signal,
		activity.mainExecutor,
		object : BiometricPrompt.AuthenticationCallback() {
			override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = finish(BiometricOutcome.Succeeded)

			override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = finish(outcome(errorCode))
		},
	)
}

private fun outcome(errorCode: Int) = when (errorCode) {
	BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT, BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> BiometricOutcome.LockedOut
	BiometricPrompt.BIOMETRIC_ERROR_HW_UNAVAILABLE, BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT, BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
	BiometricPrompt.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED,
	-> BiometricOutcome.Unavailable
	else -> BiometricOutcome.Canceled
}
