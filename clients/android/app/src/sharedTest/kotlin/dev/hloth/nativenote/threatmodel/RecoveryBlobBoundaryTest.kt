package dev.hloth.nativenote.threatmodel

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.sync.RecoveryBlob
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecoveryBlobBoundaryTest {
	@Test
	fun aBlobFromBeforeAPhraseChangeStillOpensWithTheOldWords() {
		val contentKey = AesGcm.randomBytes(32)
		val (oldWords, newWords) = AesGcm.randomBytes(32) to AesGcm.randomBytes(32)
		val backedUp = RecoveryBlob.seal(contentKey, oldWords)

		val current = RecoveryBlob.seal(contentKey, newWords)

		assertArrayEquals(contentKey, RecoveryBlob.open(backedUp, oldWords))
		assertArrayEquals(contentKey, RecoveryBlob.open(current, newWords))
		assertNull(RecoveryBlob.open(current, oldWords))
	}
}
