package dev.hloth.nativenote.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel.BiometricOffer
import dev.hloth.nativenote.model.AppModel.BiometricOutcome
import dev.hloth.nativenote.support.FakeBiometricVault
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BiometricUnlockTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val vault = FakeBiometricVault()
	private var available = true

	private fun unlocked(): AppModel {
		val model = appModel(folder.root, biometricVault = vault, biometricsAvailable = { available })
		model.await { start() }
		model.await { appStarted() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		return model
	}

	private fun touch(outcome: BiometricOutcome = BiometricOutcome.Succeeded): suspend () -> BiometricOutcome = {
		vault.touched = outcome == BiometricOutcome.Succeeded
		outcome
	}

	private fun AppModel.enable(password: String = this@BiometricUnlockTest.password, authenticate: suspend () -> BiometricOutcome = touch()) =
		runBlocking { withContext(Dispatchers.Main) { enableBiometricUnlock(password, authenticate).await() } }

	private fun AppModel.leaveAndReturn() {
		onMain { appStopped() }
		await { lock() }
		vault.touched = false
		await { appStarted() }
	}

	private fun AppModel.touchToUnlock(outcome: BiometricOutcome = BiometricOutcome.Succeeded) {
		onMain { biometricPromptShown() }
		assertEquals(BiometricOffer.Prompting, onMain { biometricOffer })
		vault.touched = outcome == BiometricOutcome.Succeeded
		await { biometricPromptEnded(outcome) }
	}

	private fun databaseKey() = UnlockKeys.databaseKey(password, LibraryFiles(folder.root).record.read()!!)

	@Test
	fun turningOnSealsTheDatabaseKeyAfterOneTouchAndReadsItBack() {
		val model = unlocked()

		assertNull(model.enable())

		assertTrue(onMain { model.isBiometricUnlockOn })
		assertEquals(1, vault.creations)
		assertArrayEquals(databaseKey(), vault.sealed)
	}

	@Test
	fun aWrongPasswordStoresNothingAndAsksForNoTouch() {
		val model = unlocked()
		var asked = false

		val failure = model.enable("wrong") {
			asked = true
			BiometricOutcome.Succeeded
		}

		assertEquals(Failure.WrongPassword, failure)
		assertFalse(asked)
		assertEquals(0, vault.creations)
		assertFalse(onMain { model.isBiometricUnlockOn })
	}

	@Test
	fun anythingShortOfATouchDeletesTheKey() {
		val model = unlocked()
		val expected = mapOf(
			BiometricOutcome.Canceled to null,
			BiometricOutcome.LockedOut to R.string.failure_biometric_locked_out,
			BiometricOutcome.Unavailable to R.string.failure_biometric_unavailable,
		)

		for ((outcome, reason) in expected) {
			val failure = model.enable(authenticate = touch(outcome))

			assertEquals(outcome.name, reason, (failure as? Failure.Unexpected)?.reason)
			assertFalse(outcome.name, vault.hasKey)
			assertFalse(outcome.name, onMain { model.isBiometricUnlockOn })
		}
	}

	@Test
	fun lockingWhileWaitingForTheTouchDeletesTheKey() {
		val model = unlocked()

		val failure = model.enable {
			model.lock()
			vault.touched = true
			BiometricOutcome.Succeeded
		}

		assertNull(failure)
		assertFalse(vault.hasKey)
		assertFalse(onMain { model.isBiometricUnlockOn })
	}

	@Test
	fun aPasswordChangeWhileWaitingForTheTouchDeletesTheKey() {
		val model = unlocked()

		model.enable {
			model.changePassword(password, "a new password").await()
			vault.touched = true
			BiometricOutcome.Succeeded
		}

		assertFalse(vault.hasKey)
	}

	@Test
	fun aTouchTooLateToReadBackTurnsNothingOn() {
		val model = unlocked()

		val failure = model.enable { BiometricOutcome.Succeeded }

		assertEquals(R.string.failure_biometric_enable, (failure as Failure.Unexpected).reason)
		assertFalse(vault.hasKey)
	}

	@Test
	fun turningOnNeedsAnUnlockedLibraryAndAvailableBiometrics() {
		val model = unlocked()
		available = false
		assertEquals(R.string.failure_biometric_unavailable, (model.enable() as Failure.Unexpected).reason)

		available = true
		model.await { lock() }
		assertEquals(R.string.failure_biometric_unlock_first, (model.enable() as Failure.Unexpected).reason)
		assertEquals(0, vault.creations)
	}

	@Test
	fun returningToTheAppPromptsAndATouchOpensTheLibrary() {
		val model = unlocked()
		model.enable()

		model.leaveAndReturn()
		assertEquals(BiometricOffer.Prompt, onMain { model.biometricOffer })
		model.touchToUnlock()

		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
		assertNull(onMain { model.failure })
	}

	@Test
	fun aManualLockOffersTheButtonWithoutPrompting() {
		val model = unlocked()
		model.enable()

		model.await { lock() }

		assertEquals(BiometricOffer.Button, onMain { model.biometricOffer })
	}

	@Test
	fun aCancelLeavesTheButtonAndALockoutHidesItUntilTheNextReturn() {
		val model = unlocked()
		model.enable()
		model.leaveAndReturn()

		model.touchToUnlock(BiometricOutcome.Canceled)
		assertEquals(BiometricOffer.Button, onMain { model.biometricOffer })
		model.touchToUnlock(BiometricOutcome.LockedOut)
		assertEquals(BiometricOffer.Hidden, onMain { model.biometricOffer })
		assertEquals(AppModel.Phase.Locked, onMain { model.phase })

		model.leaveAndReturn()
		assertEquals(BiometricOffer.Prompt, onMain { model.biometricOffer })
	}

	@Test
	fun aKeyThatNoLongerOpensTheLibraryIsForgotten() {
		val model = unlocked()
		model.enable()
		model.leaveAndReturn()
		vault.sealed = ByteArray(32) { 7 }

		model.touchToUnlock()

		assertEquals(AppModel.Phase.Locked, onMain { model.phase })
		assertEquals(R.string.failure_biometric_rejected, (onMain { model.failure } as Failure.Unexpected).reason)
		assertFalse(vault.hasKey)
		assertFalse(onMain { model.isBiometricUnlockOn })
		assertEquals(BiometricOffer.Hidden, onMain { model.biometricOffer })
	}

	@Test
	fun aKeyThatFailsToReadIsForgotten() {
		val model = unlocked()
		model.enable()
		model.leaveAndReturn()

		onMain { model.biometricPromptShown() }
		model.await { biometricPromptEnded(BiometricOutcome.Succeeded) }

		assertEquals(R.string.failure_biometric_read, (onMain { model.failure } as Failure.Unexpected).reason)
		assertFalse(vault.hasKey)
	}

	@Test
	fun anEnrollmentChangeTurnsItOffOnTheNextReturn() {
		val model = unlocked()
		model.enable()
		vault.invalidated = true

		model.leaveAndReturn()

		assertFalse(vault.hasKey)
		assertFalse(onMain { model.isBiometricUnlockOn })
		assertEquals(BiometricOffer.Hidden, onMain { model.biometricOffer })
	}

	@Test
	fun aPasswordChangeKeepsTheStoredKey() {
		val model = unlocked()
		model.enable()

		assertNull(runBlocking { withContext(Dispatchers.Main) { model.changePassword(password, "a new password").await() } })
		model.leaveAndReturn()
		model.touchToUnlock()

		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
	}

	@Test
	fun turningOffDeletesTheKey() {
		val model = unlocked()
		model.enable()

		assertNull(runBlocking { withContext(Dispatchers.Main) { model.disableBiometricUnlock().await() } })

		assertFalse(vault.hasKey)
		assertFalse(onMain { model.isBiometricUnlockOn })
	}

	@Test
	fun erasingAndSettingUpAgainDeleteTheKey() {
		val model = unlocked()
		model.enable()
		model.await { lock() }

		model.await { erase() }
		assertFalse(vault.hasKey)
		assertEquals(BiometricOffer.Hidden, onMain { model.biometricOffer })

		vault.create()
		vault.touched = true
		vault.seal(ByteArray(32))
		model.await { setUp(password) }
		assertFalse(vault.hasKey)
	}
}
