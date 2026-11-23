package dev.hloth.nativenote.crypto

import java.security.SecureRandom
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object AesGcm {
	const val NONCE_LENGTH = 12
	private const val TAG_BITS = 128
	private const val TAG_LENGTH = TAG_BITS / 8

	fun seal(key: ByteArray, plaintext: ByteArray, aad: ByteArray = ByteArray(0), nonce: ByteArray = randomBytes(NONCE_LENGTH)): ByteArray {
		require(nonce.size == NONCE_LENGTH)
		return nonce + cipher(Cipher.ENCRYPT_MODE, key, nonce, aad).doFinal(plaintext)
	}

	fun open(key: ByteArray, sealed: ByteArray, aad: ByteArray = ByteArray(0)): ByteArray? {
		if (sealed.size < NONCE_LENGTH + TAG_LENGTH) return null
		val cipher = cipher(Cipher.DECRYPT_MODE, key, sealed.copyOf(NONCE_LENGTH), aad)
		return try {
			cipher.doFinal(sealed, NONCE_LENGTH, sealed.size - NONCE_LENGTH)
		} catch (_: AEADBadTagException) {
			null
		}
	}

	fun randomBytes(count: Int): ByteArray = ByteArray(count).also { random.nextBytes(it) }

	private val random = SecureRandom()

	private fun cipher(mode: Int, key: ByteArray, nonce: ByteArray, aad: ByteArray): Cipher =
		Cipher.getInstance("AES/GCM/NoPadding").apply {
			init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
			updateAAD(aad)
		}
}
