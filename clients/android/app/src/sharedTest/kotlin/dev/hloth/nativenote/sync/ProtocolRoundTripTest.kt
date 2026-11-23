package dev.hloth.nativenote.sync

import dev.hloth.nativenote.conformance.RequestDecoding
import dev.hloth.nativenote.conformance.VectorFiles
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.KeyDerivation
import dev.hloth.nativenote.export.NoteMarkdown
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.support.RealisticCorpus
import java.util.UUID
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolRoundTripTest {
	private val random = Random(0xC0FFEE)
	private val contentKey = AesGcm.randomBytes(32)
	private val cipher = NoteCipher(contentKey)
	private val corpus = RealisticCorpus.bodies(600).mapIndexed { index, body ->
		val createdAt = random.nextLong(-62_135_596_800_000, 253_402_300_799_999)
		Content.Note(UUID.randomUUID(), createdAt, createdAt + index * 1_000L, body)
	}

	@Test
	fun everyCorpusNoteEncodesToWholeBlocksAndDecodesBack() {
		for (note in corpus) {
			val encoded = note.encoded()
			assertEquals(0, encoded.size % Content.BLOCK)
			assertTrue(encoded.size - (2 + 16 + 8 + 8 + 4 + note.body.encodeToByteArray().size + 4) < Content.BLOCK)
			assertEquals(note, Content.decode(encoded))
		}
	}

	@Test
	fun everyCorpusNoteSealsOpensAndRefusesAnyTamperedField() {
		for ((index, note) in corpus.withIndex()) {
			val content: Content = if (index % 10 == 0) Content.Tombstone(note.id, note.updatedAt) else note
			val v = (index + 1).toUInt()
			val write = cipher.seal(content, v)

			assertEquals(content, cipher.open(write))
			assertEquals(NoteCipher.Verified.Valid(content), cipher.verify(write))
			val flipped = write.payload.copyOf().also {
				val at = random.nextInt(it.size)
				it[at] = (it[at].toInt() xor 1).toByte()
			}
			for (tampered in listOf(
				Write(write.blindedId, v, write.writeId, flipped),
				Write(write.blindedId, v + 1u, write.writeId, write.payload),
				Write(cipher.blindedId(UUID.randomUUID()), v, write.writeId, write.payload),
				Write(write.blindedId, v, NoteCipher.randomWriteId(), write.payload),
			)) {
				assertEquals(NoteCipher.Verified.Unverifiable, cipher.verify(tampered))
			}
			assertEquals(NoteCipher.Verified.Unverifiable, NoteCipher(AesGcm.randomBytes(32)).verify(write))
		}
	}

	@Test
	fun aSyncRequestPackedToTheBodyLimitSealsAndOpensForTheServer() {
		val apiKey = AesGcm.randomBytes(32)
		val writes = mutableListOf<Write>()
		var length = Request.SYNC_HEADER_LENGTH
		var leftOver: Write? = null
		for ((index, note) in corpus.withIndex()) {
			val write = cipher.seal(note, (index + 1).toUInt())
			if (length + write.encodedLength > Padding.INNER_MAX) {
				leftOver = write
				break
			}
			writes += write
			length += write.encodedLength
		}
		val request = Request.Sync(since = 41u, writes = writes)

		val sealed = EnvelopeKey.fromApiKey(apiKey).seal(request.encoded())
		val serverKey = KeyDerivation.derive(apiKey, info = KeyDerivation.ENVELOPE)
		val opened = Padding.unpad(AesGcm.open(serverKey, sealed)!!)!!

		assertTrue(writes.size > 10)
		assertEquals(Padding.BODY_MAX, sealed.size - AesGcm.NONCE_LENGTH - 16)
		assertEquals(request, RequestDecoding.decode(opened))
		val overflow = Request.Sync(since = 41u, writes = writes + leftOver!!)
		assertTrue(runCatching { EnvelopeKey.fromApiKey(apiKey).seal(overflow.encoded()) }.exceptionOrNull() is EnvelopeKey.TooLarge)
	}

	@Test
	fun aResponseOpensOnlyUnderItsOwnRequestNonce() {
		val apiKey = AesGcm.randomBytes(32)
		val envelope = EnvelopeKey.fromApiKey(apiKey)
		val serverKey = KeyDerivation.derive(apiKey, info = KeyDerivation.ENVELOPE)
		val request = envelope.seal(Request.Get.encoded())
		val inner = Response.Get(3u, AesGcm.randomBytes(60)).let(::encodedGet)
		val response = AesGcm.seal(serverKey, Padding.pad(inner)!!, aad = request.copyOf(AesGcm.NONCE_LENGTH))

		assertArrayEquals(inner, envelope.open(response, request.copyOf(AesGcm.NONCE_LENGTH)))
		assertNull(envelope.open(response, envelope.seal(Request.Get.encoded()).copyOf(AesGcm.NONCE_LENGTH)))
	}

	@Test
	fun everyRandomRecoveryKeyRoundTripsThroughTwentyFourWords() {
		val mnemonic = Mnemonic(VectorFiles.wordlist())
		repeat(500) {
			val key = random.nextBytes(32)
			val words = mnemonic.words(key)

			assertEquals(Mnemonic.WORD_COUNT, words.size)
			assertArrayEquals(key, mnemonic.key(words))
		}
	}

	@Test
	fun everyCorpusNoteRendersToMarkdownAndParsesBack() {
		for (note in corpus) {
			val exported = Note(note.id, note.body, note.createdAt, note.updatedAt, dirty = true)

			assertEquals(exported, NoteMarkdown.parse(NoteMarkdown.render(exported)))
		}
		for (moment in listOf(Long.MIN_VALUE / 2, -1L, 0L, 1L, 253_402_300_800_000, Long.MAX_VALUE / 2)) {
			val exported = Note(UUID.randomUUID(), "edge", moment, moment, dirty = true)
			assertEquals(exported, NoteMarkdown.parse(NoteMarkdown.render(exported)))
		}
	}

	private fun encodedGet(response: Response.Get): ByteArray {
		val writer = WireWriter()
		writer.u8(0x02)
		writer.u32(response.v)
		writer.bytes(response.blob)
		return writer.bytes
	}
}
