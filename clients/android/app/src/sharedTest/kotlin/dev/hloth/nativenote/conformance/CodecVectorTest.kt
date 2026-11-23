package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.Padding
import dev.hloth.nativenote.sync.Response
import dev.hloth.nativenote.sync.WireException
import dev.hloth.nativenote.sync.bytes
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CodecVectorTest {
	@Test
	fun contentEncodesAndDecodesExactlyAndRejectsWhatTheSpecRejects() {
		for (vector in Vectors.load(VectorFile.Content)) {
			val encoded = vector.bytes("encoded")
			if (vector.bool("roundTrips") == true) {
				val expected = content(vector.objectOf("content"))
				assertArrayEquals(vector.name, encoded, expected.encoded())
				assertEquals(vector.name, expected, Content.decode(encoded))
				continue
			}
			assertEquals(vector.name, false, vector.bool("decodes"))
			val rejection = assertThrows(vector.name, WireException::class.java) { Content.decode(encoded) }
			assertEquals(vector.name, wireError(vector.string("error")), rejection.error)
			val prefixUuid = vector.bytesOrNull("prefixUuid")
			if (prefixUuid != null) {
				val prefix = Content.prefix(encoded)
				assertArrayEquals(vector.name, prefixUuid, prefix.id.bytes())
				assertFalse(vector.name, prefix.isKnown)
			} else {
				assertNotEquals("${vector.name} reads as a newer version", false, runCatching { Content.prefix(encoded).isKnown }.getOrNull())
			}
		}
	}

	@Test
	fun responsesDecodeExactlyAndRequestsReEncodeByteForByte() {
		val replayed = mutableSetOf<String>()
		for (vector in Vectors.load(VectorFile.Frames)) {
			val encoded = vector.bytes("encoded")
			val direction = vector.string("direction")
			val roundTrips = vector.bool("roundTrips") == true
			when {
				direction == "request" && roundTrips -> assertArrayEquals(vector.name, encoded, RequestDecoding.decode(encoded).encoded())
				direction == "response" && roundTrips -> {
					val response = Response.decode(encoded)
					assertArrayEquals(vector.name, encoded, responseBytes(response))
					if (vector.has("reason")) assertEquals(vector.name, Response.Error(errorReason(vector.string("reason"))), response)
				}
				direction == "response" && vector.bool("decodes") == true ->
					assertEquals(vector.name, Response.Error(errorReason(vector.string("reason"))), Response.decode(encoded))
				direction == "response" -> {
					val rejection = assertThrows(vector.name, WireException::class.java) { Response.decode(encoded) }
					assertEquals(vector.name, wireError(vector.string("error")), rejection.error)
				}
				else -> {
					assertTrue("${vector.name} is neither replayed nor listed as server-only", vector.name in serverOnly)
					continue
				}
			}
			replayed += vector.name
		}
		assertTrue(replayed.size >= 23)
	}

	@Test
	fun paddingFillsTheSmallestBucketAndUnpadsOnlyItsOwnOutput() {
		for (vector in Vectors.load(VectorFile.Padding)) {
			if (vector.has("innerLength")) {
				val inner = ByteArray(vector.int("innerLength")) { it.toByte() }
				if (vector.bool("pads") == false) {
					assertNull(vector.name, Padding.pad(inner))
					continue
				}
				val padded = Padding.pad(inner)!!
				assertEquals(vector.name, vector.int("paddedLength"), padded.size)
				assertArrayEquals(vector.name, vector.bytes("lengthPrefix"), padded.copyOf(4))
				assertArrayEquals(vector.name, inner, Padding.unpad(padded))
			} else {
				assertEquals(vector.name, false, vector.bool("unpads"))
				assertNull(vector.name, Padding.unpad(vector.bytes("padded")))
			}
		}
	}

	private companion object {
		val serverOnly = setOf("rejectUnknownAction", "rejectImpossibleCount", "rejectImpossibleLength", "rejectTrailingBytes", "rejectErrorAsRequest")
	}
}
