package dev.hloth.nativenote.sync

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.KeyDerivation

class EnvelopeKey private constructor(private val key: ByteArray) {
	class TooLarge : Exception("the request does not fit the body limit")

	fun seal(inner: ByteArray, nonce: ByteArray = AesGcm.randomBytes(AesGcm.NONCE_LENGTH)): ByteArray {
		val padded = Padding.pad(inner) ?: throw TooLarge()
		return AesGcm.seal(key, padded, nonce = nonce)
	}

	fun open(response: ByteArray, requestNonce: ByteArray): ByteArray? =
		AesGcm.open(key, response, requestNonce)?.let(Padding::unpad)

	companion object {
		fun fromApiKey(apiKey: ByteArray) = EnvelopeKey(KeyDerivation.derive(apiKey, info = KeyDerivation.ENVELOPE))

		fun derived(envelopeKey: ByteArray) = EnvelopeKey(envelopeKey.copyOf())

		fun apiKey(fromHex: String): ByteArray? {
			val hex = fromHex.trim()
			if (hex.length != 64) return null
			val key = ByteArray(32)
			for (index in key.indices) {
				val high = nibble(hex[2 * index])
				val low = nibble(hex[2 * index + 1])
				if (high == null || low == null) {
					key.fill(0)
					return null
				}
				key[index] = (high shl 4 or low).toByte()
			}
			return key
		}

		private fun nibble(digit: Char): Int? = when (digit) {
			in '0'..'9' -> digit - '0'
			in 'a'..'f' -> digit - 'a' + 10
			else -> null
		}
	}
}
