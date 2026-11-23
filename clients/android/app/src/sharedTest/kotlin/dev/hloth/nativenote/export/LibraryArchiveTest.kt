package dev.hloth.nativenote.export

import dev.hloth.nativenote.storage.Note
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class LibraryArchiveTest {
	@Test
	fun notesSurviveTheArchiveAndComeBackUnsynced() {
		val edited = sampleNote("Shopping\r\nbread\n---\nnot front matter").let {
			Note(it.id, it.body, it.createdAt, it.updatedAt, v = 7, ext = byteArrayOf(0x65, 0x78, 0x74))
		}
		val notes = listOf(edited, sampleNote(""), sampleNote("Shopping"))

		val restored = LibraryArchive.notes(LibraryArchive.archive(notes))

		assertEquals(notes.map { it.id }, restored.map { it.id })
		assertEquals(notes.map { it.body }, restored.map { it.body })
		assertEquals(notes.map { it.createdAt }, restored.map { it.createdAt })
		assertEquals(notes.map { it.updatedAt }, restored.map { it.updatedAt })
		assertTrue(restored.all { it.v == 0L && it.ext.isEmpty() && it.dirty })
	}

	@Test
	fun aNoteRepeatedInTheArchiveIsRefused() {
		val note = sampleNote("twice")
		val entries = listOf("a.md", "b.md").map { ZipEntry(it, NoteMarkdown.render(note).encodeToByteArray(), note.updatedAt) }

		val failure = assertThrows(LibraryArchive.Failure.RepeatedNote::class.java) { LibraryArchive.notes(ZipArchive.write(entries)) }
		assertTrue(failure.message, note.id.toString() in failure.message.orEmpty())
	}

	@Test
	fun anEntryThatIsNotTextIsRefused() {
		val entries = listOf(ZipEntry("binary.md", byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x00), 0))

		val failure = assertThrows(LibraryArchive.Failure.NotText::class.java) { LibraryArchive.notes(ZipArchive.write(entries)) }
		assertTrue(failure.message, "binary.md" in failure.message.orEmpty())
	}

	private fun sampleNote(body: String) = Note(UUID.randomUUID(), body, MOMENT, MOMENT)

	private companion object {
		const val MOMENT = 1_760_000_000_000L
	}
}
