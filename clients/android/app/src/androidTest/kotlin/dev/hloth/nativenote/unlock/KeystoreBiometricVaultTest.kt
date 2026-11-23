package dev.hloth.nativenote.unlock

import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.security.KeyStore
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class KeystoreBiometricVaultTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val alias = "native-note.biometric.test"
	private val strongBox = context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
	private val enrolled = context.getSystemService(BiometricManager::class.java)
		.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS
	private val vault by lazy { KeystoreBiometricVault(folder.root.resolve(KeystoreBiometricVault.FILE_NAME), strongBox, alias) }
	private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

	@After
	fun deleteTheTestKey() = keyStore.deleteEntry(alias)

	@Test
	fun theKeyNeedsAStrongBiometricWithinFiveSecondsAndDiesWithEnrollmentChanges() {
		assumeTrue("needs an enrolled strong biometric", enrolled)

		vault.create()

		val key = keyStore.getKey(alias, null) as SecretKey
		val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
		assertTrue(info.isUserAuthenticationRequired)
		assertEquals(KeystoreBiometricVault.VALIDITY_SECONDS, info.userAuthenticationValidityDurationSeconds)
		assertEquals(KeyProperties.AUTH_BIOMETRIC_STRONG, info.userAuthenticationType)
		assertTrue(info.isInvalidatedByBiometricEnrollment)
		assertEquals(256, info.keySize)
		assertEquals(if (strongBox) KeyProperties.SECURITY_LEVEL_STRONGBOX else KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT, info.securityLevel)
	}

	@Test
	fun withoutATouchTheKeyNeitherSealsNorOpens() {
		assumeTrue("needs an enrolled strong biometric", enrolled)
		vault.create()

		assertThrows(UserNotAuthenticatedException::class.java) { vault.seal(ByteArray(32)) }
		folder.root.resolve(KeystoreBiometricVault.FILE_NAME).writeBytes(ByteArray(60))
		assertThrows(UserNotAuthenticatedException::class.java) { vault.open() }
		assertFalse(vault.isInvalidated())
	}

	@Test
	fun aMissingOrShortBlobIsUnreadableAndDeletionTakesBoth() {
		assumeTrue("needs an enrolled strong biometric", enrolled)
		vault.create()

		assertFalse(vault.isStored)
		assertThrows(BiometricVault.Unreadable::class.java) { vault.open() }
		folder.root.resolve(KeystoreBiometricVault.FILE_NAME).writeBytes(ByteArray(59))
		assertTrue(vault.isStored)
		assertThrows(BiometricVault.Unreadable::class.java) { vault.open() }

		vault.delete()

		assertFalse(vault.isStored)
		assertFalse(keyStore.containsAlias(alias))
		assertFalse(folder.root.resolve(KeystoreBiometricVault.FILE_NAME).exists())
	}

	@Test
	fun withoutEnrolledBiometricsNoKeyIsMade() {
		assumeFalse("needs a device without an enrolled strong biometric", enrolled)

		assertTrue(runCatching { vault.create() }.isFailure)
		assertFalse(keyStore.containsAlias(alias))
		assertTrue(vault.isInvalidated())
	}
}
