package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.KeyDerivation
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.EnvelopeKey
import dev.hloth.nativenote.sync.NoteCipher
import dev.hloth.nativenote.sync.Response
import dev.hloth.nativenote.sync.Write
import dev.hloth.nativenote.sync.bytes
import dev.hloth.nativenote.sync.uuidOf
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CipherVectorTest {
	@Test
	fun blindedIdsMatchAndOneBitApartDiffer() {
		val vectors = Vectors.load(VectorFile.Blinding)
		val keys = vectors.single { it.name == "blindingKey" }
		val contentKey = keys.bytes("contentKey")
		assertArrayEquals(keys.bytes("blindingKey"), KeyDerivation.derive(contentKey, info = KeyDerivation.ID_BLIND))

		val blindedIds = vectors.filter { it.has("blindedId") }.map { vector ->
			val id = UUID.fromString(vector.string("uuid"))
			assertArrayEquals(vector.name, vector.bytes("uuidBytes"), id.bytes())
			NoteCipher(contentKey).blindedId(id).also { assertArrayEquals(vector.name, vector.bytes("blindedId"), it) }
		}
		assertEquals(2, blindedIds.map { it.toList() }.toSet().size)
	}

	@Test
	fun notePayloadsSealExactlyOpenAndRefuseAnotherVersion() {
		for (vector in Vectors.load(VectorFile.Note)) {
			val cipher = NoteCipher(vector.bytes("contentKey"))
			val v = vector.long("v").toUInt()
			val write = Write(vector.bytes("blindedId"), v, vector.bytes("writeId"), vector.bytes("payload"))
			val bumped = Write(write.blindedId, v + 1u, write.writeId, write.payload)
			assertNull(vector.name, cipher.open(bumped))
			assertEquals(vector.name, NoteCipher.Verified.Unverifiable, cipher.verify(bumped))

			val prefixUuid = vector.bytesOrNull("prefixUuid")
			if (prefixUuid != null) {
				assertArrayEquals(vector.name, prefixUuid, Content.prefix(vector.bytes("plaintext")).id.bytes())
				assertArrayEquals(vector.name, write.blindedId, cipher.blindedId(uuidOf(prefixUuid)))
				assertNull(vector.name, cipher.open(write))
				assertEquals(vector.name, NoteCipher.Verified.NewerVersion, cipher.verify(write))
				continue
			}
			val expected = content(vector.objectOf("content"))
			assertEquals(vector.name, write, cipher.seal(expected, v, write.writeId, vector.bytes("nonce")))
			assertArrayEquals(vector.name, vector.bytes("plaintext"), expected.encoded())
			assertEquals(vector.name, expected, cipher.open(write))
			assertEquals(vector.name, NoteCipher.Verified.Valid(expected), cipher.verify(write))
		}
	}

	@Test
	fun envelopesSealRequestsExactlyAndOpenOnlyTheirOwnResponses() {
		for (vector in Vectors.load(VectorFile.Envelope).filter { it.name !in serverOnly }) {
			val envelope = EnvelopeKey.derived(vector.bytes("envelopeKey"))
			val frame = vector.bytes("frame")
			vector.bytesOrNull("apiKey")?.let { apiKey ->
				assertArrayEquals(vector.name, frame, EnvelopeKey.fromApiKey(apiKey).seal(vector.bytes("inner"), vector.bytes("nonce")))
			}
			when {
				vector.name == "request" -> assertArrayEquals(frame, envelope.seal(vector.bytes("inner"), vector.bytes("nonce")))
				vector.name == "response" -> assertArrayEquals(vector.bytes("inner"), envelope.open(frame, vector.bytes("requestNonce")))
				vector.name.startsWith("errorFor") -> {
					val reply = envelope.open(vector.bytes("response"), frame.copyOf(AesGcm.NONCE_LENGTH))
					assertArrayEquals(vector.name, vector.bytes("responseInner"), reply)
					assertEquals(vector.name, Response.Error(errorReason(vector.string("reason"))), Response.decode(reply!!))
				}
				else -> {
					assertEquals(vector.name, false, vector.bool("opens"))
					val requestNonce = vector.bytesOrNull("requestNonce") ?: frame.copyOf(AesGcm.NONCE_LENGTH)
					assertNull(vector.name, envelope.open(frame, requestNonce))
				}
			}
		}
	}

	@Test
	fun anAPIKeyIsExactly64LowercaseHexCharacters() {
		val hex = "0a".repeat(32)
		assertArrayEquals(ByteArray(32) { 0x0a }, EnvelopeKey.apiKey("  $hex\n"))
		for (bad in listOf(hex.uppercase(), hex.dropLast(1), hex + "0", hex.dropLast(1) + "g", "")) {
			assertNull(bad, EnvelopeKey.apiKey(bad))
		}
	}

	private companion object {
		val serverOnly = setOf("rejectResponseOpenedAsRequest")
	}
}
