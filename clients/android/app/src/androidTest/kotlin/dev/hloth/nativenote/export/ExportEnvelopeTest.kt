package dev.hloth.nativenote.export

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.export.ExportEnvelope.Failure
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ExportEnvelopeTest {
	@Test
	fun roundTripsUnderAFreshSaltAndNonceEachTime() {
		val first = ExportEnvelope.seal(ZIP, "hunter2", FAST)
		val second = ExportEnvelope.seal(ZIP, "hunter2", FAST)

		assertFalse(first.copyOfRange(21, 37).contentEquals(second.copyOfRange(21, 37)))
		assertFalse(first.copyOfRange(37, 49).contentEquals(second.copyOfRange(37, 49)))
		assertArrayEquals(ZIP, ExportEnvelope.open(first, "hunter2"))
		assertArrayEquals(ZIP, ExportEnvelope.open(second, "hunter2"))
	}

	@Test
	fun sealsUnderTheArgon2FloorByDefault() {
		val file = ExportEnvelope.seal(ByteArray(0), "floor")

		assertArrayEquals("NNEXPORT1".encodeToByteArray(), file.copyOf(9))
		assertArrayEquals(byteArrayOf(0, 4, 0, 0, 0, 0, 0, 3, 0, 0, 0, 4), file.copyOfRange(9, 21))
	}

	@Test
	fun aWrongPassphraseAndADamagedFileFailTheSameWay() {
		val file = ExportEnvelope.seal(ZIP, "right", FAST)
		val damaged = file.copyOf().also { it[it.lastIndex] = (it[it.lastIndex].toInt() xor 0x01).toByte() }

		assertThrows(Failure.WrongPassphraseOrDamaged::class.java) { ExportEnvelope.open(file, "wrong") }
		assertThrows(Failure.WrongPassphraseOrDamaged::class.java) { ExportEnvelope.open(damaged, "right") }
	}

	@Test
	fun rejectsFilesTooShortToHoldAHeaderNonceAndTag() {
		val file = ExportEnvelope.seal(ByteArray(0), "x", FAST)
		assertEquals(9 + 12 + 16 + 12 + 16, file.size)

		for (length in 0 until file.size) {
			assertThrows("length $length", Failure.NotAnExport::class.java) { ExportEnvelope.open(file.copyOf(length), "x") }
		}
		assertArrayEquals(ByteArray(0), ExportEnvelope.open(file, "x"))
	}

	private companion object {
		val FAST = Argon2.Parameters(m = 1024, t = 1, p = 1)
		val ZIP = "PK\u0003\u0004two notes".encodeToByteArray()
	}
}
