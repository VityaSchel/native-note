package dev.hloth.nativenote.export

import dev.hloth.nativenote.storage.Note
import java.nio.charset.CharacterCodingException
import java.util.UUID

object LibraryArchive {
	sealed class Failure(message: String) : Exception(message) {
		class NotText(name: String) : Failure("$name is not UTF-8")

		class RepeatedNote(id: UUID) : Failure("$id appears twice")

		class TooLarge : Failure("larger than an export can be")
	}

	const val MAXIMUM_SIZE = 512L * 1024 * 1024

	fun archive(notes: List<Note>): ByteArray =
		ZipArchive.write(notes.zip(NoteMarkdown.fileNames(notes)) { note, name -> ZipEntry(name, NoteMarkdown.render(note).encodeToByteArray(), note.updatedAt) })

	fun notes(archive: ByteArray): List<Note> {
		val seen = HashSet<UUID>()
		return ZipArchive.read(archive).map { entry ->
			val text = try {
				entry.data.decodeToString(throwOnInvalidSequence = true)
			} catch (_: CharacterCodingException) {
				throw Failure.NotText(entry.name)
			}
			NoteMarkdown.parse(text).also { if (!seen.add(it.id)) throw Failure.RepeatedNote(it.id) }
		}
	}
}
