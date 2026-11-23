package dev.hloth.nativenote.sync

class PhraseEntry private constructor(
	private val mnemonic: Mnemonic,
	val texts: List<String>,
	private val deferredUntilLeft: Map<Int, String>,
) {
	constructor(mnemonic: Mnemonic) : this(mnemonic, List(COUNT) { "" }, emptyMap())

	sealed interface Problem {
		data class UnknownWord(val index: Int) : Problem

		data object Checksum : Problem
	}

	private enum class Word { Empty, Typing, Known, Unknown }

	val words: List<String> get() = texts.indices.map(::word)

	val key: ByteArray? get() = mnemonic.key(words)

	val opens: Boolean get() = key?.also { it.fill(0) } != null

	fun set(text: String, index: Int): Pair<PhraseEntry, Int?> {
		val old = texts[index]
		if (text == old) return this to null
		val texts = texts.toMutableList().also { it[index] = text }
		val deferred = deferredUntilLeft.toMutableMap().also { it.remove(index) }
		val pasted = words(text)
		if (pasted.isEmpty()) return PhraseEntry(mnemonic, texts, deferred) to null
		val isPaste = insertedCharacterCount(text, old) > 1
		val numbered = if (isPaste) numberedWords(text) else null
		if (numbered != null) {
			deferred[index] = numbered[index]?.let(::completed) ?: old
			for ((number, word) in numbered) {
				if (number == index) continue
				texts[number] = completed(word)
				deferred.remove(number)
			}
			return PhraseEntry(mnemonic, texts, deferred) to minOf((numbered.keys.maxOrNull() ?: index) + 1, COUNT - 1)
		}
		if (isPaste) {
			deferred[index] = completed(pasted[0])
			for ((offset, word) in pasted.withIndex().drop(1)) {
				if (index + offset >= COUNT) break
				texts[index + offset] = completed(word)
				deferred.remove(index + offset)
			}
			return PhraseEntry(mnemonic, texts, deferred) to minOf(index + pasted.size, COUNT - 1)
		}
		val spaced = text.length == old.length + 1 && text.startsWith(old) && text.last().isWhitespace()
		return PhraseEntry(mnemonic, texts, deferred) to (if (spaced) minOf(index + 1, COUNT - 1) else null)
	}

	fun complete(index: Int): PhraseEntry {
		val deferred = deferredUntilLeft.toMutableMap()
		val completed = deferred.remove(index) ?: cleaned(texts[index])
		return PhraseEntry(mnemonic, texts.toMutableList().also { it[index] = completed }, deferred)
	}

	fun isInvalid(index: Int, editing: Int?): Boolean = when (state(index)) {
		Word.Empty, Word.Known -> false
		Word.Typing -> index != editing
		Word.Unknown -> true
	}

	fun problem(editing: Int?): Problem? {
		texts.indices.firstOrNull { isInvalid(it, editing) }?.let { return Problem.UnknownWord(it) }
		return if (texts.indices.all { state(it) == Word.Known } && !opens) Problem.Checksum else null
	}

	fun couldBeListWord(text: String): Boolean {
		val word = normalized(text)
		return word.isEmpty() || mnemonic.wordlist.any { it.startsWith(word) }
	}

	private fun state(index: Int): Word {
		val word = word(index)
		return when {
			word.isEmpty() -> Word.Empty
			word in mnemonic.wordlist -> Word.Known
			mnemonic.wordlist.any { it.startsWith(word) } -> Word.Typing
			else -> Word.Unknown
		}
	}

	private fun word(index: Int) = deferredUntilLeft[index] ?: normalized(texts[index])

	private fun cleaned(text: String): String {
		val trimmed = text.trim()
		return if (trimmed.all(Char::isLetter)) completed(trimmed.lowercase()) else trimmed
	}

	private fun completed(prefix: String): String {
		val matches = mnemonic.wordlist.filter { it.startsWith(prefix) }
		return if (matches.size == 1 && prefix.isNotEmpty()) matches[0] else prefix
	}

	companion object {
		const val COUNT = Mnemonic.WORD_COUNT

		private fun normalized(text: String) = text.trim().lowercase()

		private fun isWordSeparator(character: Char) = character.isWhitespace() || character == ','

		private fun tokens(text: String): List<String> {
			val tokens = mutableListOf<String>()
			val token = StringBuilder()
			for (character in text) {
				if (!isWordSeparator(character)) {
					token.append(character)
				} else if (token.isNotEmpty()) {
					tokens += token.toString()
					token.clear()
				}
			}
			if (token.isNotEmpty()) tokens += token.toString()
			return tokens
		}

		private fun lettersOnly(text: String) = text.lowercase().trim { !it.isLetter() }

		private fun words(text: String) = tokens(text).map(::lettersOnly).filter { it.isNotEmpty() }

		private fun numberedWords(text: String): Map<Int, String>? {
			var number: Int? = null
			val placed = HashMap<Int, String>()
			for (token in tokens(text)) {
				val digits = token.takeWhile { it in '0'..'9' }
				val rest = token.drop(digits.length).dropWhile { it == '.' || it == ')' }
				if (digits.isNotEmpty()) {
					val value = digits.toIntOrNull()
					if (number != null || value == null || value !in 1..COUNT) return null
					number = value - 1
				}
				val word = lettersOnly(rest)
				if (word.isEmpty()) continue
				val field = number ?: return null
				if (field in placed) return null
				placed[field] = word
				number = null
			}
			return if (placed.size > 1 && number == null) placed else null
		}

		private fun insertedCharacterCount(text: String, old: String): Int {
			val prefix = text.zip(old).takeWhile { (new, was) -> new == was }.size
			val suffix = text.drop(prefix).reversed().zip(old.drop(prefix).reversed()).takeWhile { (new, was) -> new == was }.size
			return text.length - prefix - suffix
		}
	}
}
