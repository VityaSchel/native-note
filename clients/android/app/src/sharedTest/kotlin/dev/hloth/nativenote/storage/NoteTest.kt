package dev.hloth.nativenote.storage

import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteTest {
	private fun note(body: String) = Note(UUID.randomUUID(), body, 0, 0)

	@Test
	fun exposesTheFirstLineAsTheTitle() {
		assertEquals("Groceries", note("  Groceries \t\nmilk\neggs").title)
		assertEquals("", note("").title)
		assertEquals("", note("\nsecond line").title)
	}

	@Test
	fun titleStopsAtAnyLineEnding() {
		for (ending in listOf("\n", "\r", "\r\n", "\u000B", "\u000C", "\u0085", "\u2028", "\u2029")) {
			assertEquals("ending ${ending.map { it.code }}", "first", note("first${ending}second").title)
		}
	}

	@Test
	fun titleTrimsEverySpaceSeparator() {
		assertEquals("title", note("\u00A0\u3000title\u2003").title)
	}

	@Test
	fun previewIsTheRestOnOneLine() {
		assertEquals("milk eggs", note("Groceries\nmilk\neggs").preview)
		assertEquals("milk  eggs", note("Groceries\n\n  milk\n\neggs  \n").preview)
		assertEquals("milk eggs", note("Groceries\r\nmilk\r\neggs").preview)
		assertEquals("", note("Groceries").preview)
		assertEquals("", note("Groceries\n \n\t").preview)
	}

	@Test
	fun anUnsyncedCopyKeepsTextTimestampsAndExtAsANewDirtyNote() {
		val original = Note(UUID.randomUUID(), "body", 10, 20, deleted = true, dirty = false, v = 7, ext = byteArrayOf(1, 2))

		val copy = original.unsyncedCopy()

		assertNotEquals(original.id, copy.id)
		assertEquals("body", copy.body)
		assertEquals(10L, copy.createdAt)
		assertEquals(20L, copy.updatedAt)
		assertTrue(copy.dirty)
		assertEquals(false, copy.deleted)
		assertEquals(0L, copy.v)
		assertArrayEquals(byteArrayOf(1, 2), copy.ext)
	}

	@Test
	fun notesCompareExtByContent() {
		val id = UUID.randomUUID()

		assertEquals(Note(id, "a", 1, 2, ext = byteArrayOf(3)), Note(id, "a", 1, 2, ext = byteArrayOf(3)))
		assertNotEquals(Note(id, "a", 1, 2, ext = byteArrayOf(3)), Note(id, "a", 1, 2, ext = byteArrayOf(4)))
	}
}
