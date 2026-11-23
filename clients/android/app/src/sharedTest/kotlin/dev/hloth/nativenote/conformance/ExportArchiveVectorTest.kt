package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.export.LibraryArchive
import dev.hloth.nativenote.export.ZipArchive
import org.junit.Assert.assertEquals
import org.junit.Test

class ExportArchiveVectorTest {
	@Test
	fun theSealedZipHoldsTheListedNoteFiles() {
		val vector = Vectors.load(VectorFile.Export).first { it.name == "export" }
		val zip = vector.bytes("zip")
		val listed = vector.objects("entries")

		val entries = ZipArchive.read(zip)

		assertEquals(listed.map { it.getString("name") }, entries.map { it.name })
		assertEquals(listed.map { it.getString("markdown").encodeToByteArray().toList() }, entries.map { it.data.toList() })
		assertEquals(listed.size, LibraryArchive.notes(zip).size)
	}
}
