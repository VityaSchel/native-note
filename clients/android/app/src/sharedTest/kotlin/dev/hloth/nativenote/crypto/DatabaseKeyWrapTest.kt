package dev.hloth.nativenote.crypto

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DatabaseKeyWrapTest {
	private val key = AesGcm.randomBytes(32)
	private val unlockKey = AesGcm.randomBytes(32)

	@Test
	fun wrapsIntoSixtyBytesThatOpenOnlyUnderTheirUnlockKey() {
		val wrapped = DatabaseKeyWrap.wrap(key, unlockKey)

		assertEquals(60, wrapped.size)
		assertArrayEquals(key, DatabaseKeyWrap.unwrap(wrapped, unlockKey))
		assertNull(DatabaseKeyWrap.unwrap(wrapped, AesGcm.randomBytes(32)))
	}

	@Test
	fun refusesATamperedOrResizedWrap() {
		val wrapped = DatabaseKeyWrap.wrap(key, unlockKey)

		for (index in wrapped.indices) {
			val tampered = wrapped.copyOf().also { it[index] = (it[index].toInt() xor 0x80).toByte() }
			assertNull(DatabaseKeyWrap.unwrap(tampered, unlockKey))
		}
		assertNull(DatabaseKeyWrap.unwrap(wrapped.copyOf(59), unlockKey))
		assertNull(DatabaseKeyWrap.unwrap(wrapped + 0, unlockKey))
	}

	@Test
	fun bindsTheWrapToItsPurpose() {
		val sealedWithoutLabel = AesGcm.seal(unlockKey, key)

		assertNull(DatabaseKeyWrap.unwrap(sealedWithoutLabel, unlockKey))
	}
}
