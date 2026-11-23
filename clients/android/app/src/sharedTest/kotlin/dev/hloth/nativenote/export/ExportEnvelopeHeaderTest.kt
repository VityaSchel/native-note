package dev.hloth.nativenote.export

import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.export.ExportEnvelope.Failure
import kotlin.time.Duration.Companion.seconds
import kotlin.time.measureTime
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportEnvelopeHeaderTest {
	@Test
	fun recognizesOnlyTheExportMagic() {
		assertTrue(ExportEnvelope.isEncrypted(file(claiming = FAST)))
		assertFalse(ExportEnvelope.isEncrypted(ZIP))
		assertFalse(ExportEnvelope.isEncrypted("NNEXPORT2".encodeToByteArray() + ByteArray(64)))
		assertFalse(ExportEnvelope.isEncrypted("NNEXPORT".encodeToByteArray()))
		assertFalse(ExportEnvelope.isEncrypted(ByteArray(0)))
	}

	@Test
	fun aFileFromANewerExportVersionIsRefusedAsSuch() {
		for (head in listOf("NNEXPORT2", "NNEXPORT0", "NNEXPORT\u0000", "NNEXPORTv2", "NNEXPORT\u00FF")) {
			val sealed = file(claiming = FAST)
			val file = head.encodeToByteArray() + sealed.copyOfRange(9, sealed.size)

			assertFalse(head, ExportEnvelope.isEncrypted(file))
			assertThrows(head, Failure.NewerVersion::class.java) { ExportEnvelope.refuseNewerVersion(file) }
			assertThrows(head, Failure.NewerVersion::class.java) { ExportEnvelope.open(file, "x") }
		}
	}

	@Test
	fun onlyAnotherByteAfterTheExportFamilyIsANewerVersion() {
		for (file in listOf("", "NNEXPORT", "NNEXPORT1", "PK\u0003\u0004", "NNEXPOR2")) {
			ExportEnvelope.refuseNewerVersion(file.encodeToByteArray())
		}
	}

	@Test
	fun refusesAHeaderAskingForSixtyFourGibibytesWithoutHashing() {
		val hostile = file(claiming = Argon2.Parameters(m = 64 * 1024 * 1024, t = 3, p = 4))

		val elapsed = measureTime {
			assertThrows(Failure.ParametersOutOfBounds::class.java) { ExportEnvelope.open(hostile, "x") }
		}
		assertTrue("$elapsed", elapsed < 1.seconds)
	}

	@Test
	fun refusesParametersOutsideTheBoundsInEitherDirection() {
		val outside = listOf(
			Argon2.Parameters(m = 2 * 1024 * 1024 + 1, t = 3, p = 4),
			Argon2.Parameters(m = 1024, t = 0, p = 1),
			Argon2.Parameters(m = 1024, t = 11, p = 1),
			Argon2.Parameters(m = 1024, t = 1, p = 0),
			Argon2.Parameters(m = 1024, t = 1, p = 17),
			Argon2.Parameters(m = 31, t = 1, p = 4),
			Argon2.Parameters(m = UInt.MAX_VALUE.toInt(), t = UInt.MAX_VALUE.toInt(), p = UInt.MAX_VALUE.toInt()),
		)

		for (parameters in outside) {
			assertFalse("$parameters", ExportEnvelope.isWithinBounds(parameters))
			assertThrows("$parameters", Failure.ParametersOutOfBounds::class.java) {
				ExportEnvelope.open(file(claiming = parameters), "x")
			}
			assertThrows("$parameters", Failure.ParametersOutOfBounds::class.java) {
				ExportEnvelope.seal(ZIP, "x", parameters)
			}
		}
	}

	@Test
	fun acceptsTheFloorAndEveryEdgeOfTheBounds() {
		assertTrue(ExportEnvelope.isWithinBounds(Argon2.Parameters.floor))
		assertTrue(ExportEnvelope.isWithinBounds(Argon2.Parameters(m = 8, t = 1, p = 1)))
		assertTrue(ExportEnvelope.isWithinBounds(Argon2.Parameters(m = 128, t = 1, p = 16)))
		assertTrue(ExportEnvelope.isWithinBounds(Argon2.Parameters(m = 2 * 1024 * 1024, t = 10, p = 16)))
	}

	private fun file(claiming: Argon2.Parameters) = ExportEnvelope.header(claiming, ByteArray(16)) + ByteArray(12 + 16)

	private companion object {
		val FAST = Argon2.Parameters(m = 1024, t = 1, p = 1)
		val ZIP = "PK\u0003\u0004two notes".encodeToByteArray()
	}
}
