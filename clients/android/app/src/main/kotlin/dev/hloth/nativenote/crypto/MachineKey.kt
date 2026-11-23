package dev.hloth.nativenote.crypto

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory

class MachineKey private constructor(val id: ByteArray, private val key: SecretKey) {
	class BoundToAnotherDevice(cause: Throwable? = null) : Exception("the machine key is not on this device", cause)

	val keyInfo: KeyInfo get() = SecretKeyFactory.getInstance(key.algorithm, PROVIDER).getKeySpec(key, KeyInfo::class.java) as KeyInfo

	val isHardwareBacked get() = keyInfo.securityLevel != KeyProperties.SECURITY_LEVEL_SOFTWARE

	fun machineId(): ByteArray {
		val operation = try {
			Mac.getInstance(ALGORITHM).run {
				init(key)
				doFinal(KeyDerivation.MACHINE_ID.encodeToByteArray())
			}
		} catch (failure: java.security.GeneralSecurityException) {
			throw BoundToAnotherDevice(failure)
		}
		try {
			return KeyDerivation.derive(operation, info = KeyDerivation.MACHINE_ID)
		} finally {
			operation.fill(0)
		}
	}

	fun delete() = keyStore().deleteEntry(alias(id))

	companion object {
		const val ID_LENGTH = 16
		private const val PROVIDER = "AndroidKeyStore"
		private const val ALGORITHM = KeyProperties.KEY_ALGORITHM_HMAC_SHA256

		fun create(strongBox: Boolean): MachineKey {
			val id = AesGcm.randomBytes(ID_LENGTH)
			val key = try {
				generate(id, strongBox)
			} catch (_: StrongBoxUnavailableException) {
				generate(id, strongBox = false)
			}
			return MachineKey(id, key)
		}

		fun load(id: ByteArray): MachineKey {
			val key = try {
				keyStore().getKey(alias(id), null) as? SecretKey
			} catch (failure: java.security.GeneralSecurityException) {
				throw BoundToAnotherDevice(failure)
			}
			return MachineKey(id, key ?: throw BoundToAnotherDevice())
		}

		private fun generate(id: ByteArray, strongBox: Boolean): SecretKey = KeyGenerator.getInstance(ALGORITHM, PROVIDER).run {
			init(KeyGenParameterSpec.Builder(alias(id), KeyProperties.PURPOSE_SIGN).setIsStrongBoxBacked(strongBox).build())
			generateKey()
		}

		fun deleteAll() {
			val keyStore = keyStore()
			keyStore.aliases().toList().filter { it.startsWith(ALIAS_PREFIX) }.forEach(keyStore::deleteEntry)
		}

		private const val ALIAS_PREFIX = "native-note.machine."

		private fun alias(id: ByteArray) = ALIAS_PREFIX + id.toHexString()

		private fun keyStore() = KeyStore.getInstance(PROVIDER).apply { load(null) }
	}
}
