package dev.hloth.nativenote.storage

import java.util.UUID

class Note(
	val id: UUID,
	val body: String,
	val createdAt: Long,
	val updatedAt: Long,
	val deleted: Boolean = false,
	val dirty: Boolean = false,
	val v: Long = 0,
	val ext: ByteArray = ByteArray(0),
) {
	val title: String get() = body.takeWhile { !it.isNewline() }.trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }

	fun preview(limit: Int = body.length): String {
		val newline = body.indexOfFirst { it.isNewline() }
		if (newline < 0) return ""
		val start = (newline until body.length).firstOrNull { !body[it].isWhitespace() } ?: return ""
		val shown = body.substring(start, if (limit < body.length - start) start + limit else body.length)
		return shown.replace("\r\n", "\n").trim().split { it.isNewline() }.joinToString(" ")
	}

	fun copy(body: String = this.body, updatedAt: Long = this.updatedAt, dirty: Boolean = this.dirty) =
		Note(id, body, createdAt, updatedAt, deleted, dirty, v, ext)

	fun withV(v: Long) = Note(id, body, createdAt, updatedAt, deleted, dirty, v, ext)

	fun unsyncedCopy(id: UUID = UUID.randomUUID()) = Note(id, body, createdAt, updatedAt, dirty = true, ext = ext)

	override fun equals(other: Any?) = other is Note && id == other.id && body == other.body && createdAt == other.createdAt &&
		updatedAt == other.updatedAt && deleted == other.deleted && dirty == other.dirty && v == other.v && ext.contentEquals(other.ext)

	override fun hashCode() = id.hashCode() * 31 + body.hashCode()

	override fun toString() = "Note($id, ${body.length} chars, updated $updatedAt, v$v${if (deleted) ", deleted" else ""}${if (dirty) ", dirty" else ""})"
}

private fun Char.isNewline() = this in '\n'..'\r' || this == '\u0085' || this == '\u2028' || this == '\u2029'

private fun String.split(isSeparator: (Char) -> Boolean): List<String> {
	val parts = mutableListOf<String>()
	var start = 0
	for (index in indices) if (isSeparator(this[index])) {
		parts += substring(start, index)
		start = index + 1
	}
	return parts + substring(start)
}
