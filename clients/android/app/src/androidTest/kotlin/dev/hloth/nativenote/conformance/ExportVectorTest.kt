package dev.hloth.nativenote.conformance

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.export.ExportEnvelope
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ExportVectorTest {
	private class Reference {
		val vector = Vectors.load(VectorFile.Export).first { it.name == "export" }
		val passphrase = vector.string("passphrase")
		val parameters = Argon2.Parameters(m = vector.int("m"), t = vector.int("t"), p = vector.int("p"))
		val salt = vector.bytes("salt")
	}

	@Test
	fun derivesTheHeaderAndKeyFromTheFixedInputs() {
		val reference = Reference()

		assertArrayEquals(reference.vector.bytes("header"), ExportEnvelope.header(reference.parameters, reference.salt))
		assertArrayEquals(reference.vector.bytes("exportKey"), ExportEnvelope.key(reference.passphrase, reference.salt, reference.parameters))
	}

	@Test
	fun sealsTheFixedInputsToExactlyTheReferenceFile() {
		val reference = Reference()

		val file = ExportEnvelope.seal(
			reference.vector.bytes("zip"),
			reference.passphrase,
			reference.parameters,
			reference.salt,
			reference.vector.bytes("nonce"),
		)

		assertArrayEquals(reference.vector.bytes("file"), file)
	}

	@Test
	fun everyCaseOpensOrIsRejectedAsDeclared() {
		val cases = Vectors.load(VectorFile.Export)
		assertEquals(12, cases.size)

		for (vector in cases) {
			val file = vector.bytes("file")
			val passphrase = vector.string("passphrase")
			val opens = checkNotNull(vector.bool("opens")) { "case ${vector.name}" }
			val newer = vector.has("outcome") && vector.string("outcome") == "newerVersion"
			assertEquals(vector.name, !newer, ExportEnvelope.isEncrypted(file))
			if (newer) {
				assertThrows(vector.name, ExportEnvelope.Failure.NewerVersion::class.java) { ExportEnvelope.refuseNewerVersion(file) }
			} else {
				ExportEnvelope.refuseNewerVersion(file)
			}

			if (opens) {
				assertArrayEquals(vector.name, vector.bytes("zip"), ExportEnvelope.open(file, passphrase))
			} else {
				val expected = when {
					newer -> ExportEnvelope.Failure.NewerVersion::class.java
					vector.name.startsWith("rejectParameters") -> ExportEnvelope.Failure.ParametersOutOfBounds::class.java
					else -> ExportEnvelope.Failure.WrongPassphraseOrDamaged::class.java
				}
				assertEquals(vector.name, expected, runCatching { ExportEnvelope.open(file, passphrase) }.exceptionOrNull()?.javaClass)
			}
		}
	}
}
