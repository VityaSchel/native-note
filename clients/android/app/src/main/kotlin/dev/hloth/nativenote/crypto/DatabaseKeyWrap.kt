package dev.hloth.nativenote.crypto

object DatabaseKeyWrap {
	const val WRAPPED_LENGTH = AesGcm.NONCE_LENGTH + 32 + 16
	private val associatedData = "native-note/localdb-key/v1".encodeToByteArray()

	fun wrap(key: ByteArray, unlockKey: ByteArray): ByteArray = AesGcm.seal(unlockKey, key, associatedData)

	fun unwrap(wrapped: ByteArray, unlockKey: ByteArray): ByteArray? {
		if (wrapped.size != WRAPPED_LENGTH) return null
		return AesGcm.open(unlockKey, wrapped, associatedData)
	}
}
