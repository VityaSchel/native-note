package dev.hloth.nativenote.unlock

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import java.io.File
import java.io.IOException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

interface BiometricVault {
	val isStored: Boolean

	fun isInvalidated(): Boolean

	fun create()

	fun seal(databaseKey: ByteArray)

	fun open(): ByteArray

	fun delete()

	class Unreadable(cause: Throwable? = null) : Exception("the key saved for biometric unlock cannot be read", cause)
}

class KeystoreBiometricVault(
	private val blob: File,
	private val strongBox: Boolean,
	private val alias: String = ALIAS,
) : BiometricVault {
	private val keyStore get() = KeyStore.getInstance(PROVIDER).apply { load(null) }

	override val isStored get() = blob.exists() && keyStore.containsAlias(alias)

	override fun isInvalidated(): Boolean {
		val key = secretKey() ?: return true
		return try {
			Cipher.getInstance(TRANSFORMATION).init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, ByteArray(NONCE_LENGTH)))
			false
		} catch (_: UserNotAuthenticatedException) {
			false
		} catch (_: KeyPermanentlyInvalidatedException) {
			true
		}
	}

	override fun create() {
		delete()
		val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
			.setKeySize(256)
			.setBlockModes(KeyProperties.BLOCK_MODE_GCM)
			.setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
			.setUserAuthenticationRequired(true)
			.setUserAuthenticationParameters(VALIDITY_SECONDS, KeyProperties.AUTH_BIOMETRIC_STRONG)
			.setInvalidatedByBiometricEnrollment(true)
			.setIsStrongBoxBacked(strongBox)
			.build()
		KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER).apply { init(spec) }.generateKey()
	}

	override fun seal(databaseKey: ByteArray) {
		val key = secretKey() ?: throw BiometricVault.Unreadable()
		val cipher = Cipher.getInstance(TRANSFORMATION).apply {
			init(Cipher.ENCRYPT_MODE, key)
			updateAAD(AAD)
		}
		UnlockRecordFile.durablyReplace(blob, cipher.iv + cipher.doFinal(databaseKey))
	}

	override fun open(): ByteArray {
		val key = secretKey() ?: throw BiometricVault.Unreadable()
		val sealed = try {
			blob.readBytes()
		} catch (failure: IOException) {
			throw BiometricVault.Unreadable(failure)
		}
		if (sealed.size != NONCE_LENGTH + DATABASE_KEY_LENGTH + TAG_BITS / 8) throw BiometricVault.Unreadable()
		val cipher = Cipher.getInstance(TRANSFORMATION).apply {
			init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, sealed, 0, NONCE_LENGTH))
			updateAAD(AAD)
		}
		return cipher.doFinal(sealed, NONCE_LENGTH, sealed.size - NONCE_LENGTH)
	}

	override fun delete() {
		keyStore.deleteEntry(alias)
		if (blob.exists() && !blob.delete()) throw IOException("${blob.name} could not be deleted")
	}

	private fun secretKey() = keyStore.getKey(alias, null) as? SecretKey

	companion object {
		const val ALIAS = "native-note.biometric"
		const val FILE_NAME = "biometric-key"
		const val VALIDITY_SECONDS = 5
		private const val PROVIDER = "AndroidKeyStore"
		private const val TRANSFORMATION = "AES/GCM/NoPadding"
		private const val NONCE_LENGTH = 12
		private const val TAG_BITS = 128
		private const val DATABASE_KEY_LENGTH = 32
		private val AAD = "native-note/biometric-key/v1".encodeToByteArray()
	}
}
