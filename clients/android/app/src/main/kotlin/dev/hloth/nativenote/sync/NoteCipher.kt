package dev.hloth.nativenote.sync

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.KeyDerivation
import java.util.UUID

class NoteCipher(private val contentKey: ByteArray) {
	sealed interface Verified {
		data class Valid(val content: Content) : Verified

		data object NewerVersion : Verified

		data object Unverifiable : Verified
	}

	private val blindingKey = KeyDerivation.derive(contentKey, info = KeyDerivation.ID_BLIND)

	fun blindedId(id: UUID): ByteArray = KeyDerivation.hmacSha256(blindingKey, id.bytes()).copyOf(Write.ID_LENGTH)

	fun seal(content: Content, v: UInt, writeId: ByteArray = randomWriteId(), nonce: ByteArray = AesGcm.randomBytes(AesGcm.NONCE_LENGTH)): Write {
		val blindedId = blindedId(content.id)
		val key = noteKey(writeId)
		try {
			return Write(blindedId, v, writeId, AesGcm.seal(key, content.encoded(), binding(blindedId, v, writeId), nonce))
		} finally {
			key.fill(0)
		}
	}

	fun open(write: Write): Content? = decrypt(write)?.let { runCatching { Content.decode(it) }.getOrNull() }

	fun verify(change: Write): Verified {
		val plaintext = decrypt(change) ?: return Verified.Unverifiable
		val prefix = runCatching { Content.prefix(plaintext) }.getOrNull() ?: return Verified.Unverifiable
		if (!blindedId(prefix.id).contentEquals(change.blindedId)) return Verified.Unverifiable
		if (!prefix.isKnown) return Verified.NewerVersion
		return runCatching { Content.decode(plaintext) }.map(Verified::Valid).getOrDefault(Verified.Unverifiable)
	}

	private fun decrypt(write: Write): ByteArray? {
		val key = noteKey(write.writeId)
		try {
			return AesGcm.open(key, write.payload, binding(write.blindedId, write.v, write.writeId))
		} finally {
			key.fill(0)
		}
	}

	private fun noteKey(writeId: ByteArray) = KeyDerivation.derive(contentKey, salt = writeId, info = KeyDerivation.NOTE)

	companion object {
		fun randomWriteId(): ByteArray = AesGcm.randomBytes(Write.ID_LENGTH)

		private fun binding(blindedId: ByteArray, v: UInt, writeId: ByteArray): ByteArray {
			val writer = WireWriter()
			writer.fixed(blindedId)
			writer.u32(v)
			writer.fixed(writeId)
			return writer.bytes
		}
	}
}
