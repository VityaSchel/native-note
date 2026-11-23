package dev.hloth.nativenote.sync

import dev.hloth.nativenote.conformance.VectorFiles
import java.util.Collections
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun PhraseEntry.type(keys: String, index: Int): Pair<PhraseEntry, Int?> =
	keys.fold(Pair<PhraseEntry, Int?>(this, null)) { (entry, _), character -> entry.set(entry.texts[index] + character, index) }

private class Fields(mnemonic: Mnemonic) {
	var entry = PhraseEntry(mnemonic)
		private set
	val shown = MutableList(PhraseEntry.COUNT) { "" }
	var focus = 0
		private set

	fun edit(text: String) {
		val index = focus
		shown[index] = text
		val next = render { it.set(text, index) }
		if (next != null && next != focus) move(next)
	}

	fun move(index: Int) {
		val left = focus
		focus = index
		val ending = shown[left]
		render { it.set(ending, left) }
		render { it.complete(left) to Unit }
	}

	private fun <T> render(change: (PhraseEntry) -> Pair<PhraseEntry, T>): T {
		val before = entry.texts
		val (changed, result) = change(entry)
		entry = changed
		for (index in shown.indices) {
			if (entry.texts[index] != before[index]) shown[index] = entry.texts[index]
		}
		return result
	}
}

class PhraseEntryTest {
	private val mnemonic = Mnemonic(VectorFiles.wordlist())
	private val key = ByteArray(32) { (it * 7 + 3).toByte() }
	private val phrase = mnemonic.words(key)

	private fun entry(words: List<String>) = PhraseEntry(mnemonic).set(words.joinToString(" "), 0).first

	private fun swapped(words: List<String>, first: Int, second: Int) = words.toMutableList().also { Collections.swap(it, first, second) }

	@Test
	fun aPasteFillsEveryFieldFromTheOneItLandsInAndFocusesTheLast() {
		val (entry, focus) = PhraseEntry(mnemonic).set("\n" + phrase.joinToString(" \t").uppercase() + "\n", 0)

		assertEquals(23, focus)
		assertEquals(phrase, entry.words)
		assertTrue(entry.opens)
		assertArrayEquals(key, entry.key)
		assertNull(entry.problem(23))
		assertEquals(phrase, entry.complete(0).texts)
	}

	@Test
	fun aCopyOfTheNumberedWordsPastesAsTheWords() {
		val numbered = phrase.mapIndexed { index, word -> "${index + 1}. $word" }

		val (entry, _) = PhraseEntry(mnemonic).set(numbered.joinToString("\t"), 0)

		assertEquals(phrase, entry.words)
	}

	@Test
	fun aNumberedListInAnyOrderPutsEachWordInItsNumberedField() {
		val numbered = phrase.mapIndexed { index, word -> "${index + 1}. $word" }

		val (entry, focus) = PhraseEntry(mnemonic).set(numbered.reversed().joinToString("\n"), 6)

		assertEquals(23, focus)
		assertEquals(phrase, entry.words)
		assertEquals(phrase, entry.complete(6).texts)
	}

	@Test
	fun oneCopiedColumnLandsInItsOwnFieldsWhereverItIsPasted() {
		val column = (9..16).joinToString("\n") { "${if (it < 10) "\u2007" else ""}$it. ${phrase[it - 1]}" }

		val (entry, focus) = PhraseEntry(mnemonic).set(column, 0)

		assertEquals(16, focus)
		val words = entry.complete(0).words
		assertEquals(setOf(""), words.subList(0, 8).toSet())
		assertEquals(phrase.subList(8, 16), words.subList(8, 16))
		assertEquals(setOf(""), words.subList(16, 24).toSet())
	}

	@Test
	fun numbersThatDoNotFollowEveryWordPasteInOrder() {
		val words = phrase
		for ((text, count) in listOf("1. ${words[0]} ${words[1]} 3. ${words[2]}" to 3, "1. ${words[0]} 1. ${words[1]}" to 2, "30. ${words[0]} 2. ${words[1]}" to 2)) {
			val entry = PhraseEntry(mnemonic).set(text, 0).first.complete(0)

			assertEquals(text, words.take(count) + "", entry.words.take(count + 1))
		}
	}

	@Test
	fun aPasteLandingPartWayFillsTheFieldsAfterItAndDropsWhatDoesNotFit() {
		val (entry, focus) = PhraseEntry(mnemonic).set(phrase.joinToString(" "), 20)

		assertEquals(23, focus)
		assertEquals(setOf(""), entry.words.subList(0, 20).toSet())
		assertEquals(phrase.take(4), entry.words.subList(20, 24))
	}

	@Test
	fun aPasteOverASelectedWordReplacesItAndMovesOn() {
		val (selected, _) = PhraseEntry(mnemonic).type("abandon", 4)

		val (able, afterAble) = selected.set("5. Able", 4)
		assertEquals(5, afterAble)
		assertEquals("able", able.words[4])
		val left = able.complete(4)
		assertEquals("able", left.texts[4])

		val (zooZone, afterZooZone) = left.set("zoo zone", 4)
		assertEquals(6, afterZooZone)
		assertEquals(listOf("zoo", "zone"), zooZone.words.subList(4, 6))
		val (z, afterZ) = zooZone.set("z", 4)
		assertNull(afterZ)
		assertEquals("z", z.texts[4])
		assertEquals("z", z.words[4])
		assertEquals("zone", z.words[5])
	}

	@Test
	fun typingOverAPasteInTheLastFieldDropsThePastedWord() {
		val (pasted, afterPaste) = PhraseEntry(mnemonic).set("zoo", 23)
		assertEquals(23, afterPaste)
		val (typed, afterTyping) = pasted.set("z", 23)
		assertNull(afterTyping)

		assertEquals("z", typed.words[23])
		assertEquals("z", typed.complete(23).texts[23])
	}

	@Test
	fun aPasteSplitsAtWhitespaceAndCommasSoAStrayCharacterKeepsAWordWhole() {
		val (strayed, _) = PhraseEntry(mnemonic).type("skil;l", 5)
		val (beforeNext, _) = strayed.set("tunnel", 6)

		val (doubled, afterDoubled) = beforeNext.set("skil;lskill", 5)
		assertEquals(6, afterDoubled)
		assertEquals("skil;lskill", doubled.words[5])
		assertEquals("tunnel", doubled.texts[6])
		assertTrue(doubled.isInvalid(5, 6))

		val (bracketed, afterBracketed) = doubled.set("(abandon),ability;", 10)
		assertEquals(12, afterBracketed)
		assertEquals(listOf("abandon", "ability"), bracketed.words.subList(10, 12))
	}

	@Test
	fun aRePasteOverTheSameFirstWordStillFillsEveryField() {
		val entry = entry(phrase).complete(0)
		val corrected = swapped(phrase, 5, 6)

		val (repasted, focus) = entry.set(corrected.joinToString(" "), 0)

		assertEquals(23, focus)
		assertEquals(corrected, repasted.words)
	}

	@Test
	fun aPasteOfFourLetterAbbreviationsCompletesEveryWord() {
		val (entry, focus) = PhraseEntry(mnemonic).set(phrase.joinToString(" ") { it.take(4) }, 0)

		assertEquals(23, focus)
		assertEquals(phrase, entry.words)
		assertTrue(entry.opens)
		assertArrayEquals(key, entry.key)
		assertEquals(phrase.drop(1), entry.texts.drop(1))
	}

	@Test
	fun aSpaceInAnEmptyFieldOrAPasteWithoutLettersStaysAsTyped() {
		val (space, afterSpace) = PhraseEntry(mnemonic).set(" ", 1)
		val (digits, afterDigits) = space.set("12", 2)
		val (dashes, afterDashes) = digits.set("--", 3)
		assertNull(afterSpace)
		assertNull(afterDigits)
		assertNull(afterDashes)

		assertEquals(listOf(" ", "12", "--"), dashes.texts.subList(1, 4))
		assertEquals("", dashes.texts[4])
		assertEquals("", dashes.complete(1).texts[1])
		val fields = Fields(mnemonic)
		for (character in "abandon  ability") {
			fields.edit(fields.shown[fields.focus] + character)
		}
		assertEquals(1, fields.focus)
		assertEquals(" ability", fields.shown[1])
		assertEquals("", fields.shown[2])
	}

	@Test
	fun aFieldSendingItsTextAgainAsItEndsKeepsThePastedWord() {
		val pasted = phrase.joinToString(" ")
		val (entry, _) = PhraseEntry(mnemonic).set(pasted, 0)

		val (resent, focus) = entry.set(pasted, 0)
		assertNull(focus)

		assertEquals(phrase[0], resent.complete(0).texts[0])
	}

	@Test
	fun aPastedOrDictatedWordCompletesAndMovesOn() {
		val (aban, afterAban) = PhraseEntry(mnemonic).set("Aban", 3)
		val (ya, afterYa) = aban.set("Ya", 5)

		assertEquals(4, afterAban)
		assertEquals(6, afterYa)
		assertEquals("abandon", ya.words[3])
		assertEquals("yard", ya.words[5])
	}

	@Test
	fun aSpaceAfterAWordMovesOnAndLeavingCompletesIt() {
		val (aba, afterAba) = PhraseEntry(mnemonic).type("aba", 0)
		assertNull(afterAba)
		assertEquals("aba", aba.words[0])
		assertFalse(aba.isInvalid(0, 0))

		val (spaced, afterSpace) = aba.type(" ", 0)
		assertEquals(1, afterSpace)
		val first = spaced.complete(0)
		assertEquals("abandon", first.texts[0])

		val (ab, afterAb) = first.type("ab ", 1)
		assertEquals(2, afterAb)
		val second = ab.complete(1)
		assertEquals("ab", second.texts[1])
		assertTrue(second.isInvalid(1, 2))
	}

	@Test
	fun aSpaceInTheLastFieldStaysThere() {
		val (entry, focus) = PhraseEntry(mnemonic).type("zoo ", 23)

		assertEquals(23, focus)
		assertEquals("zoo", entry.words[23])
		assertEquals("zoo ", entry.texts[23])
		assertEquals("zoo", entry.complete(23).texts[23])
	}

	@Test
	fun aStrayCharacterTypedInAWordStaysInItsFieldAndASpaceLeavesTheNextAlone() {
		val (beforeNext, _) = PhraseEntry(mnemonic).set("tunnel", 6)

		val (strayed, afterStray) = beforeNext.type("Skil;l", 5)
		val (digit, afterDigit) = strayed.type("aban1", 0)
		assertNull(afterStray)
		assertNull(afterDigit)
		assertEquals("Skil;l", digit.texts[5])
		assertEquals("aban1", digit.texts[0])
		assertTrue(digit.isInvalid(5, 5))
		assertEquals(PhraseEntry.Problem.UnknownWord(0), digit.problem(5))

		val (spaced, afterSpace) = digit.type(" ", 5)
		assertEquals(6, afterSpace)
		val left = spaced.complete(5)
		assertEquals("Skil;l", left.texts[5])
		assertEquals("tunnel", left.words[6])
		assertTrue(left.isInvalid(5, 6))
	}

	@Test
	fun spacesAroundAWordAreKeptAsTypedAndIgnoredWhenChecking() {
		val (a, afterA) = PhraseEntry(mnemonic).type(" A", 0)
		assertNull(afterA)
		assertEquals(" A", a.texts[0])
		assertEquals("a", a.words[0])
		assertFalse(a.isInvalid(0, 0))
		val (aba, afterAba) = a.type("ba ", 0)
		assertEquals(1, afterAba)
		assertEquals("abandon", aba.complete(0).texts[0])

		val spaced = phrase.withIndex().fold(PhraseEntry(mnemonic)) { entry, (index, word) -> entry.type(" $word ", index).first }
		assertTrue(spaced.texts.all { it.startsWith(" ") && it.endsWith(" ") })
		assertTrue(spaced.opens)
		assertArrayEquals(key, spaced.key)
	}

	@Test
	fun aSpaceTypedInsideAWordDoesNotSplitIt() {
		val (abandon, _) = PhraseEntry(mnemonic).type("abandon", 0)

		val (split, afterSplit) = abandon.set("aba ndon", 0)
		assertNull(afterSplit)
		val (spaced, afterSpace) = split.type(" ", 0)
		assertEquals(1, afterSpace)
		val (space, _) = spaced.set(" ", 2)
		val (a, afterA) = space.set("a ", 2)
		assertNull(afterA)
		assertEquals("a ", a.texts[2])

		assertEquals("aba ndon", a.words[0])
		assertEquals("", a.words[1])
		assertTrue(a.isInvalid(0, 1))
	}

	@Test
	fun leavingAFieldCompletesItAndAPrefixLeftBehindIsAnUnknownWord() {
		val typed = PhraseEntry(mnemonic).type("zon", 4).first.type("zo", 5).first

		val entry = typed.complete(4).complete(5)

		assertEquals("zone", entry.texts[4])
		assertEquals("zo", entry.texts[5])
		assertFalse(entry.isInvalid(5, 5))
		assertTrue(entry.isInvalid(5, 6))
		assertEquals(PhraseEntry.Problem.UnknownWord(5), entry.problem(6))
		assertNull(entry.problem(5))
	}

	@Test
	fun aWordOffTheListIsReportedAtOnceWhereverItIs() {
		val entry = PhraseEntry(mnemonic).type("abandon", 0).first.type("bitcoins", 7).first

		assertTrue(entry.isInvalid(7, 7))
		assertEquals(PhraseEntry.Problem.UnknownWord(7), entry.problem(7))
		assertFalse(entry.opens)
	}

	@Test
	fun twentyFourListWordsThatFailTheChecksumAreReportedAndDoNotOpen() {
		val swapped = swapped(phrase, 0, 1)
		assertNull(mnemonic.key(swapped))

		val entry = entry(swapped)

		assertEquals(PhraseEntry.Problem.Checksum, entry.problem(null))
		assertFalse(entry.opens)
		assertNull(entry.key)
	}

	@Test
	fun anUnfinishedPhraseHasNoProblemYet() {
		val entry = entry(phrase.take(23))

		assertNull(entry.problem(23))
		assertFalse(entry.opens)
	}

	@Test
	fun everyFieldShowsItsTextThroughRandomTypingPastingAndMoving() {
		val keys = "abcdeilnorstuz ;1".toList()
		val samples = phrase + listOf("ab", "zo", "skil;l", "5. able", "zoo zone", " aba ", "--", "")
		for (seed in 1L..4L) {
			val random = Random(seed)
			val fields = Fields(mnemonic)
			for (step in 0 until 2000) {
				val index = fields.focus
				val shown = fields.shown[index]
				val before = fields.entry.texts
				var typed = true
				when (random.nextInt(10)) {
					in 0 until 6 -> fields.edit(shown + keys.random(random))
					6 -> fields.edit(shown.dropLast(1))
					7 -> {
						val paste = samples.random(random)
						fields.edit(if (random.nextBoolean()) paste else shown + paste)
						typed = false
					}
					8 -> fields.edit(keys.random(random).toString())
					else -> fields.move(random.nextInt(PhraseEntry.COUNT))
				}
				val case = "seed $seed step $step"
				assertEquals(case, fields.shown, fields.entry.texts)
				if (typed) {
					assertTrue(case, fields.entry.texts.indices.all { it == index || fields.entry.texts[it] == before[it] })
					assertEquals(case, fields.shown[index].trim().lowercase(), fields.entry.words[index])
				}
			}
		}
	}

	@Test
	fun typingThroughEveryFieldOpensThePhrase() {
		val fields = Fields(mnemonic)

		for (word in phrase) {
			for (character in word.take(4) + " ") {
				fields.edit(fields.shown[fields.focus] + character)
			}
		}
		fields.move(0)

		assertEquals(phrase, fields.shown)
		assertTrue(fields.entry.opens)
		assertArrayEquals(key, fields.entry.key)
	}

	@Test
	fun aListWordOrTheStartOfOneCouldBeAListWordAndATypoCannot() {
		val entry = PhraseEntry(mnemonic)

		assertTrue(entry.couldBeListWord("abandon"))
		assertTrue(entry.couldBeListWord(" Aban "))
		assertTrue(entry.couldBeListWord(""))
		assertFalse(entry.couldBeListWord("zzzz"))
	}
}
