package dev.hloth.nativenote.threatmodel

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.NoteCipher
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

class PayloadLengthTest {
	private val cipher = NoteCipher(AesGcm.randomBytes(32))
	private val fields = 1 + 1 + 16 + 8 + 8 + 4 + 4

	private fun length(content: Content) = cipher.seal(content, 1u).payload.size

	private fun note(body: String) = Content.Note(UUID.randomUUID(), 1, 2, body)

	@Test
	fun aDeletionLooksLikeAShortNote() {
		val short = length(note("1234"))

		assertEquals(short, length(Content.Tombstone(UUID.randomUUID(), 3)))
		assertEquals(short, length(note("")))
		assertEquals(short, length(note("a".repeat(Content.BLOCK - fields))))
	}

	@Test
	fun aLongerNoteGrowsOnlyByWholeBlocks() {
		val one = length(note("a".repeat(Content.BLOCK - fields)))
		val two = length(note("a".repeat(Content.BLOCK - fields + 1)))

		assertEquals(Content.BLOCK, two - one)
		assertEquals(two, length(note("a".repeat(2 * Content.BLOCK - fields))))
	}
}
