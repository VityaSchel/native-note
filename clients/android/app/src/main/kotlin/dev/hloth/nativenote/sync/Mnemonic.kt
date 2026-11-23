package dev.hloth.nativenote.sync

import java.security.MessageDigest

class Mnemonic(wordlistFile: ByteArray) {
	class UnexpectedWordlist : Exception("the wordlist is not the pinned BIP39 English list")

	val wordlist: List<String>

	init {
		if (sha256(wordlistFile).toHexString() != WORDLIST_SHA256) throw UnexpectedWordlist()
		wordlist = wordlistFile.decodeToString().split('\n').filter(String::isNotEmpty)
	}

	private val indexOf = wordlist.withIndex().associate { (index, word) -> word to index }

	fun words(key: ByteArray): List<String> {
		require(key.size == ENTROPY_BYTES)
		val checksum = sha256(key)[0].toInt() and 0xff
		fun bit(index: Int): Int =
			if (index < ENTROPY_BYTES * 8) key[index / 8].toInt() shr (7 - index % 8) and 1 else checksum shr (7 - (index - ENTROPY_BYTES * 8)) and 1
		return List(WORD_COUNT) { word ->
			wordlist[(0 until BITS_PER_WORD).fold(0) { value, offset -> value shl 1 or bit(word * BITS_PER_WORD + offset) }]
		}
	}

	fun key(words: List<String>): ByteArray? {
		if (words.size != WORD_COUNT) return null
		val indices = words.map { indexOf[it] ?: return null }.toIntArray()
		fun bit(index: Int) = indices[index / BITS_PER_WORD] shr (BITS_PER_WORD - 1 - index % BITS_PER_WORD) and 1
		val entropy = ByteArray(ENTROPY_BYTES) { byte -> (0 until 8).fold(0) { value, offset -> value shl 1 or bit(byte * 8 + offset) }.toByte() }
		val expected = (0 until 8).fold(0) { value, offset -> value shl 1 or bit(ENTROPY_BYTES * 8 + offset) }
		indices.fill(0)
		if ((sha256(entropy)[0].toInt() and 0xff) != expected) {
			entropy.fill(0)
			return null
		}
		return entropy
	}

	companion object {
		const val WORD_COUNT = 24
		private const val BITS_PER_WORD = 11
		private const val ENTROPY_BYTES = 32
		private const val WORDLIST_SHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"

		private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
	}
}
