package dev.hloth.nativenote.support

import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.UserNotAuthenticatedException
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.sync.HttpTransport
import dev.hloth.nativenote.sync.Mnemonic
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.unlock.BiometricVault
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockParameters
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

val cheapArgon = Argon2.Parameters(m = 8 * 1024, t = 1, p = 4)

fun unboundParameters() = UnlockParameters(AesGcm.randomBytes(UnlockParameters.SALT_LENGTH), cheapArgon, null)

fun appModel(
	directory: File,
	makeParameters: () -> UnlockParameters = ::unboundParameters,
	calibrate: () -> Argon2.Parameters = { cheapArgon },
	hasSecureHardware: Boolean = true,
	searchNotes: (NoteStore, String) -> List<Note> = { store, text -> store.search(text) },
	biometricVault: BiometricVault = FakeBiometricVault(),
	biometricsAvailable: () -> Boolean = { false },
	exportParameters: Argon2.Parameters = cheapArgon,
	memoryAvailable: () -> Long = { Long.MAX_VALUE },
	makeTransport: (String) -> SyncTransport = ::HttpTransport,
	syncDelayMillis: Long = 30_000,
) = AppModel(
	LibraryFiles(directory),
	hasSecureHardware,
	makeParameters,
	calibrate,
	searchNotes = searchNotes,
	biometricVault = biometricVault,
	biometricsAvailable = biometricsAvailable,
	exportParameters = exportParameters,
	memoryAvailable = memoryAvailable,
	makeTransport = makeTransport,
	syncDelayMillis = syncDelayMillis,
	loadMnemonic = { Mnemonic(InstrumentationRegistry.getInstrumentation().targetContext.assets.open("english.txt").use { it.readBytes() }) },
)

class FakeBiometricVault : BiometricVault {
	var hasKey = false
	var sealed: ByteArray? = null
	var touched = false
	var invalidated = false
	var creations = 0

	override val isStored get() = hasKey && sealed != null

	override fun isInvalidated() = invalidated

	override fun create() {
		delete()
		creations++
		hasKey = true
	}

	override fun seal(databaseKey: ByteArray) {
		if (!hasKey) throw BiometricVault.Unreadable()
		if (!touched) throw UserNotAuthenticatedException()
		sealed = databaseKey.copyOf()
	}

	override fun open(): ByteArray {
		if (!hasKey) throw BiometricVault.Unreadable()
		if (invalidated) throw KeyPermanentlyInvalidatedException()
		if (!touched) throw UserNotAuthenticatedException()
		return sealed?.copyOf() ?: throw BiometricVault.Unreadable()
	}

	override fun delete() {
		hasKey = false
		sealed = null
	}
}

fun <T> onMain(action: () -> T): T = runBlocking { withContext(Dispatchers.Main) { action() } }

fun AppModel.await(action: AppModel.() -> Job) = runBlocking { withContext(Dispatchers.Main) { action() }.join() }
