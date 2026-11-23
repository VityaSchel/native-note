package dev.hloth.nativenote.unlock

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UnlockRecordTest {
	private val bound = UnlockRecord(
		UnlockParameters(AesGcm.randomBytes(16), Argon2.Parameters(m = 524_288, t = 3, p = 4), AesGcm.randomBytes(16)),
		AesGcm.randomBytes(60),
	)
	private val unbound = UnlockRecord(UnlockParameters(AesGcm.randomBytes(16), Argon2.Parameters.floor, null), AesGcm.randomBytes(60))

	@Test
	fun encodesToAFixedLayoutAndDecodesBack() {
		assertEquals(1 + 16 + 12 + 1 + 16 + 60, bound.encoded().size)
		assertEquals(1 + 16 + 12 + 1 + 60, unbound.encoded().size)
		assertEquals(bound, UnlockRecord.decode(bound.encoded()))
		assertEquals(unbound, UnlockRecord.decode(unbound.encoded()))
	}

	@Test
	fun anythingButOneCanonicalEncodingIsUnreadable() {
		val encoded = bound.encoded()
		val unreadable = listOf(
			ByteArray(0),
			encoded.copyOf(encoded.size - 1),
			encoded + 0,
			encoded.copyOf().also { it[0] = 2 },
			unbound.encoded().copyOf().also { it[1 + 16 + 12] = 2 },
			unbound.encoded().copyOf().also { it[1 + 16 + 12] = 1 },
		)

		for (bytes in unreadable) {
			assertThrows(UnlockRecord.Unreadable::class.java) { UnlockRecord.decode(bytes) }
		}
	}
}
