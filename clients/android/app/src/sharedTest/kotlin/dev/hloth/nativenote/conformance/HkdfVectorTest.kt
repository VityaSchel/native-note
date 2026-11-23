package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.crypto.KeyDerivation
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class HkdfVectorTest {
	private val cases = Vectors.load(VectorFile.Hkdf)

	@Test
	fun everyLabelMatches() {
		for (vector in cases) {
			val ikm = vector.bytesOrNull("ikm") ?: (vector.bytes("argonOut") + vector.bytes("machineId"))
			val okm = KeyDerivation.derive(ikm, vector.bytesOrNull("salt") ?: ByteArray(0), vector.string("info"), vector.int("length"))

			assertArrayEquals(vector.name, vector.bytes("okm"), okm)
		}
	}

	@Test
	fun labelConstantsMatchTheSpec() {
		val labels = cases.associate { it.name to it.string("info") }

		assertEquals(KeyDerivation.ENVELOPE, labels["envelopeKey"])
		assertEquals(KeyDerivation.ID_BLIND, labels["blindingKey"])
		assertEquals(KeyDerivation.NOTE, labels["noteKey"])
		assertEquals(KeyDerivation.UNLOCK, labels["unlockKey"])
		assertEquals(KeyDerivation.MACHINE_ID, labels["machineId"])
	}

	@Test
	fun unlockKeysMatchWithAndWithoutAMachineId() {
		for (name in listOf("unlockKey", "unlockKeyWithoutMachineId")) {
			val vector = cases.single { it.name == name }
			val key = KeyDerivation.unlockKey(
				argonOut = vector.bytesOrNull("argonOut") ?: vector.bytes("ikm"),
				machineId = vector.bytesOrNull("machineId"),
				localSalt = vector.bytes("salt"),
			)

			assertArrayEquals(name, vector.bytes("okm"), key)
		}
	}
}
