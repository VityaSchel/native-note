package dev.hloth.nativenote.export

import dev.hloth.nativenote.storage.Note
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteFileNameTest {
	@Test
	fun importedNotesAreLiveDirtyAndUnsynced() {
		val original = Note(UUID.randomUUID(), "Synced elsewhere", CREATED, UPDATED, deleted = true, dirty = false, v = 12, ext = byteArrayOf(1, 2, 3))

		val rendered = NoteMarkdown.render(original)
		val parsed = NoteMarkdown.parse(rendered)

		assertTrue(
			rendered,
			rendered.startsWith("---\nid: ${original.id.toString().lowercase()}\ncreated: 2026-09-24T21:00:00.123Z\nupdated: 2026-09-25T08:30:15.456Z\n---\n"),
		)
		assertFalse(parsed.deleted)
		assertTrue(parsed.dirty)
		assertEquals(0L, parsed.v)
		assertTrue(parsed.ext.isEmpty())
	}

	@Test
	fun namesEachFileAfterItsTitle() {
		assertEquals(listOf("Groceries.md", "Trip to Lviv.md"), fileNames(listOf("Groceries", "  Trip to Lviv  ")))
		assertTrue(NoteMarkdown.fileNames(emptyList()).isEmpty())
	}

	@Test
	fun replacesCharactersThatAreUnsafeInFileNames() {
		val cases = listOf(
			"a/b\\c:d|e" to "a-b-c-d-e",
			"2026/09/24" to "2026-09-24",
			"What? *Really* \"quoted\" <tag>" to "What Really quoted tag",
			"Tab\tseparated" to "Tab separated",
			"Nul\u0000escape\u001Bdelete\u007Fcsi\u009Bend" to "Nul escape delete csi end",
			"...hidden" to "hidden",
			". . .spaced dots" to "spaced dots",
			"\u0000.leading control" to "leading control",
			"Trailing dots..." to "Trailing dots",
			"Trailing mix . ." to "Trailing mix",
			"v1.2 release notes" to "v1.2 release notes",
			"CON" to "_CON",
			"con.backup" to "_con.backup",
			"Aux .txt" to "_Aux .txt",
			"lpt9" to "_lpt9",
			"COM\u00B9" to "_COM\u00B9",
			"Console" to "Console",
			"NULL" to "NULL",
			"Cafe\u0301" to "Caf\u00E9",
		)

		for ((title, expected) in cases) {
			assertEquals(title, utf8(listOf("$expected.md")), utf8(fileNames(listOf(title))))
		}
	}

	@Test
	fun prefixesAWindowsReservedNameThatTheCapReveals() {
		val spaces = " ".repeat(246)
		val dots = ".".repeat(250)

		assertEquals(listOf("_CON.md"), fileNames(listOf("CON${spaces}x")))
		assertEquals(listOf("_aux.md"), fileNames(listOf("aux$spaces    tail")))
		assertEquals(listOf("_NUL.md"), fileNames(listOf("NUL${dots}x")))
		assertEquals(listOf("_lpt1.md"), fileNames(listOf("lpt1${spaces}x.txt")))
	}

	@Test
	fun namesAFileUntitledWhenTheTitleLeavesNothing() {
		for (title in listOf("", "   ", "\t\u3000", "...", "?*<>\"", "\u0000\u0001\u007F", " . . ")) {
			assertEquals(title, listOf("Untitled.md"), fileNames(listOf(title)))
		}
	}

	@Test
	fun numbersUntitledNotes() {
		assertEquals(
			listOf("Untitled.md", "Untitled 2.md", "Untitled 3.md"),
			NoteMarkdown.fileNames(listOf(note("", created = 0), note("\n\nbody", created = 1), note("???", created = 2))),
		)
	}

	@Test
	fun numbersThousandsOfUntitledNotesInSequence() {
		val names = fileNames(List(3_000) { "" })

		assertEquals("Untitled.md", names.first())
		assertEquals((2..3_000).map { "Untitled $it.md" }, names.drop(1))
	}

	@Test
	fun capsLongTitlesWithoutSplittingAGraphemeCluster() {
		val family = "\uD83D\uDC68\u200D\uD83D\uDC69\u200D\uD83D\uDC67\u200D\uD83D\uDC66"
		val stacked = "x\u0301\u0302"

		assertEquals(25, family.encodeToByteArray().size)
		assertEquals(utf8(listOf(family.repeat(9) + ".md")), utf8(fileNames(listOf(family.repeat(20)))))
		assertEquals(utf8(listOf(stacked.repeat(49) + ".md")), utf8(fileNames(listOf(stacked.repeat(60)))))
		assertEquals(utf8(listOf(a(247) + ".md")), utf8(fileNames(listOf(a(247) + family))))
		assertEquals(utf8(listOf(a(246) + "\u00E9.md")), utf8(fileNames(listOf(a(246) + "\u00E9b"))))
		assertEquals(utf8(listOf(a(246) + "\u00E9.md")), utf8(fileNames(listOf(a(246) + "e\u0301b"))))
		assertEquals(utf8(listOf(a(247) + ".md")), utf8(fileNames(listOf(a(247) + "\u00E9"))))
		assertEquals(listOf(a(247) + ".md"), fileNames(listOf(a(247) + " b")))
		assertEquals(listOf(a(246) + ".md"), fileNames(listOf(a(246) + ". b")))
	}

	@Test
	fun aSingleClusterLongerThanTheCapIsUntitled() {
		assertEquals(listOf("Untitled.md"), fileNames(listOf("x" + "\u0301".repeat(200))))
	}

	@Test
	fun leavesRoomForTwoDigitNumbersAndKeepsEveryNameUnder255Bytes() {
		val names = fileNames(List(120) { a(300) })
		val capped = a(248)

		assertEquals("$capped.md", names[0])
		assertEquals("$capped 2.md", names[1])
		assertEquals("$capped 99.md", names[98])
		assertEquals(254, names[98].encodeToByteArray().size)
		assertEquals(a(247) + " 100.md", names[99])
		assertTrue(names.all { it.encodeToByteArray().size < 255 })
		assertEquals(names.size, names.toSet().size)
	}

	@Test
	fun titlesThatMatchOnlyBeyondTheCapAreNumbered() {
		val capped = a(248)

		assertEquals(listOf("$capped.md", "$capped 2.md"), fileNames(listOf(capped + "X", capped + "Y")))
	}

	@Test
	fun numbersNamesThatDifferOnlyInCase() {
		assertEquals(listOf("Note.md", "note 2.md", "NOTE 3.md"), fileNames(listOf("Note", "note", "NOTE")))
	}

	@Test
	fun numbersNamesThatDifferOnlyInUnicodeNormalization() {
		assertEquals(
			utf8(listOf("Caf\u00E9.md", "Caf\u00E9 2.md", "CAF\u00C9 3.md", "caf\u00C9 4.md")),
			utf8(fileNames(listOf("Caf\u00E9", "Cafe\u0301", "CAFE\u0301", "caf\u00C9"))),
		)
	}

	@Test
	fun numbersNamesThatMatchUnderFullCaseFolding() {
		assertEquals(
			listOf("Stra\u00DFe.md", "STRASSE 2.md", "\u039F\u0394\u039F\u03A3.md", "\u03BF\u03B4\u03BF\u03C2 2.md"),
			fileNames(listOf("Stra\u00DFe", "STRASSE", "\u039F\u0394\u039F\u03A3", "\u03BF\u03B4\u03BF\u03C2")),
		)
	}

	@Test
	fun numbersTitlesThatBecomeTheSameName() {
		assertEquals(listOf("a-b.md", "a-b 2.md", "a-b 3.md", "a-b 4.md"), fileNames(listOf("a/b", "a:b", "a-b", ".a-b.")))
	}

	@Test
	fun aTitleThatLooksNumberedKeepsItsOwnName() {
		assertEquals(listOf("Note.md", "Note 3.md", "Note 2.md"), fileNames(listOf("Note", "Note", "Note 2")))
		assertEquals(listOf("Note.md", "note 3.md", "note 2.md"), fileNames(listOf("Note", "note", "note 2")))
	}

	@Test
	fun theOldestNoteKeepsTheUnnumberedName() {
		val newer = note("Plan", created = 2_000)
		val older = note("Plan", created = 1_000)

		assertEquals(listOf("Plan 2.md", "Plan.md"), NoteMarkdown.fileNames(listOf(newer, older)))
	}

	@Test
	fun theSameNotesGetTheSameNamesInAnyOrder() {
		val titles = listOf("Plan", "plan", "Idea", "", "PLAN 2")
		val notes = List(15) { note(titles[it % titles.size], created = (it % 3).toLong()) }
		val names = NoteMarkdown.fileNames(notes)
		val nameByID = notes.map { it.id }.zip(names).toMap()

		assertEquals(names, NoteMarkdown.fileNames(notes))
		assertEquals(names.size, names.map { it.lowercase() }.toSet().size)
		for (reordered in listOf(notes.reversed(), notes.drop(7) + notes.take(7))) {
			assertEquals(reordered.map { nameByID[it.id] }, NoteMarkdown.fileNames(reordered))
		}
	}

	private fun note(body: String, created: Long = CREATED) = Note(UUID.randomUUID(), body, created, UPDATED)

	private fun fileNames(titles: List<String>) = NoteMarkdown.fileNames(titles.mapIndexed { index, title -> note("$title\nsecond line", created = index.toLong()) })

	private fun utf8(strings: List<String>) = strings.map { it.encodeToByteArray().toList() }

	private fun a(count: Int) = "a".repeat(count)

	private companion object {
		const val CREATED = 1_790_283_600_123L
		const val UPDATED = 1_790_325_015_456L
	}
}
