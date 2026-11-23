package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.sync.Mnemonic
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class MnemonicVectorTest {
	private val mnemonic = Mnemonic(VectorFiles.wordlist())

	@Test
	fun usesThePinnedListAndRejectsBadChecksumsCountsAndWords() {
		for (vector in Vectors.load(VectorFile.Mnemonic)) {
			if (vector.name == "wordlist") {
				assertEquals(vector.int("count"), mnemonic.wordlist.size)
				assertEquals(vector.string("first"), mnemonic.wordlist.first())
				assertEquals(vector.string("last"), mnemonic.wordlist.last())
				continue
			}
			val words = vector.string("mnemonic").split(' ')
			val decoded = mnemonic.key(words)
			assertEquals(vector.name, vector.bool("decodes"), decoded != null)
			vector.bytesOrNull("entropy")?.let { entropy ->
				assertArrayEquals(vector.name, entropy, decoded)
				assertEquals(vector.name, words, mnemonic.words(entropy))
			}
		}
	}

	@Test
	fun anyOtherWordlistIsRefused() {
		val altered = VectorFiles.wordlist().also { it[0] = 'b'.code.toByte() }

		assertThrows(Mnemonic.UnexpectedWordlist::class.java) { Mnemonic(altered) }
	}
}
