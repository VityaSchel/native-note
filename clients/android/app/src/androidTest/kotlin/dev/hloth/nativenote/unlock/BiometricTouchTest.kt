package dev.hloth.nativenote.unlock

import android.content.pm.PackageManager
import android.security.keystore.UserNotAuthenticatedException
import androidx.activity.ComponentActivity
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.model.AppModel.BiometricOutcome
import dev.hloth.nativenote.ui.rememberBiometricPrompt
import java.security.KeyStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BiometricTouchTest {
	@get:Rule
	val compose = createAndroidComposeRule<ComponentActivity>()

	@get:Rule
	val folder = TemporaryFolder()

	private val context = InstrumentationRegistry.getInstrumentation().targetContext
	private val alias = "native-note.biometric.touch-test"
	private val vault by lazy {
		KeystoreBiometricVault(
			folder.root.resolve(KeystoreBiometricVault.FILE_NAME),
			context.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE),
			alias,
		)
	}

	@Before
	fun onlyWithSomeoneToTouch() = assumeTrue("run with -e touch true and a finger ready", InstrumentationRegistry.getArguments().getString("touch") == "true")

	@After
	fun deleteTheTestKey() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(alias)

	@Test
	fun oneTouchSealsAndReadsBackThenTheWindowCloses() {
		vault.create()
		lateinit var authenticate: suspend () -> BiometricOutcome
		compose.setContent { authenticate = rememberBiometricPrompt("Touch to test Native Note") }
		compose.waitForIdle()

		val outcome = runBlocking { withContext(Dispatchers.Main) { authenticate() } }
		val key = AesGcm.randomBytes(32)
		vault.seal(key)
		val read = vault.open()

		assertEquals(BiometricOutcome.Succeeded, outcome)
		assertArrayEquals(key, read)
		Thread.sleep((KeystoreBiometricVault.VALIDITY_SECONDS + 1) * 1_000L)
		assertThrows(UserNotAuthenticatedException::class.java) { vault.open() }
	}
}
