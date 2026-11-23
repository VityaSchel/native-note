package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.export.NoteMarkdown
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.sync.uuidOf
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MarkdownVectorTest {
	@Test
	fun everyCaseRendersToItsFileAndParsesBack() {
		val cases = Vectors.load(VectorFile.Markdown)
		assertTrue(cases.isNotEmpty())

		for (vector in cases) {
			val note = Note(
				id = uuidOf(vector.bytes("uuid")),
				body = vector.string("body"),
				createdAt = vector.long("createdAt"),
				updatedAt = vector.long("updatedAt"),
				dirty = true,
			)
			val file = vector.string("markdown")

			assertArrayEquals(vector.name, file.encodeToByteArray(), NoteMarkdown.render(note).encodeToByteArray())
			assertEquals(vector.name, note, NoteMarkdown.parse(file))
		}
	}
}
