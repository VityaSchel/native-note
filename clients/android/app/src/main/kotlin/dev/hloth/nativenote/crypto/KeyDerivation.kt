package dev.hloth.nativenote.crypto

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object KeyDerivation {
	const val ENVELOPE = "native-note/envelope/v1"
	const val ID_BLIND = "native-note/id-blind/v1"
	const val NOTE = "native-note/note/v1"
	const val UNLOCK = "native-note/unlock/v1"
	const val MACHINE_ID = "native-note/machine-id/v1"

	private const val HASH_LENGTH = 32

	fun derive(ikm: ByteArray, salt: ByteArray = ByteArray(0), info: String, length: Int = 32): ByteArray {
		require(length in 1..255 * HASH_LENGTH)
		val pseudorandomKey = hmacSha256(if (salt.isEmpty()) ByteArray(HASH_LENGTH) else salt, ikm)
		val okm = ByteArray(length)
		var block = ByteArray(0)
		try {
			for (counter in 1..(length + HASH_LENGTH - 1) / HASH_LENGTH) {
				val next = hmacSha256(pseudorandomKey, block + info.encodeToByteArray() + counter.toByte())
				block.fill(0)
				block = next
				val offset = (counter - 1) * HASH_LENGTH
				block.copyInto(okm, offset, 0, minOf(HASH_LENGTH, length - offset))
			}
			return okm
		} finally {
			block.fill(0)
			pseudorandomKey.fill(0)
		}
	}

	fun unlockKey(argonOut: ByteArray, machineId: ByteArray?, localSalt: ByteArray): ByteArray {
		val ikm = argonOut + (machineId ?: ByteArray(0))
		try {
			return derive(ikm, localSalt, UNLOCK)
		} finally {
			ikm.fill(0)
		}
	}

	fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray =
		Mac.getInstance("HmacSHA256").run {
			init(SecretKeySpec(key, "HmacSHA256"))
			doFinal(data)
		}
}
