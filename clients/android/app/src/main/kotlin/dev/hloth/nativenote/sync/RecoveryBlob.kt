package dev.hloth.nativenote.sync

import dev.hloth.nativenote.crypto.AesGcm

object RecoveryBlob {
	fun seal(contentKey: ByteArray, recoveryKey: ByteArray, nonce: ByteArray = AesGcm.randomBytes(AesGcm.NONCE_LENGTH)): ByteArray =
		AesGcm.seal(recoveryKey, contentKey, nonce = nonce)

	fun open(blob: ByteArray, recoveryKey: ByteArray): ByteArray? {
		val plaintext = AesGcm.open(recoveryKey, blob) ?: return null
		if (plaintext.size == 32) return plaintext
		plaintext.fill(0)
		return null
	}
}
