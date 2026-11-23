package dev.hloth.nativenote.storage

import dev.hloth.nativenote.sync.bytes
import dev.hloth.nativenote.sync.uuidOf
import java.util.UUID

class NoteStore(val connection: SQLiteConnection) {
	sealed interface Saved {
		data object InPlace : Saved

		data class Copied(val id: UUID) : Saved
	}

	fun save(note: Note): Saved = connection.transaction {
		val held = connection.prepare("SELECT 1 FROM note WHERE uuid = ?1").use {
			it.bind(1, note.id.bytes())
			it.step()
		}
		when {
			!held -> {
				put(note, pulled = false)
				Saved.InPlace
			}
			wasPulled(note.id, after = note.v) -> {
				val copy = note.unsyncedCopy()
				put(copy, pulled = false)
				Saved.Copied(copy.id)
			}
			else -> {
				connection.prepare("UPDATE note SET body = ?2, updatedAt = ?3, deleted = ?4, dirty = ?5, pulled = 0 WHERE uuid = ?1 AND deleted = 0").use {
					it.bind(1, note.id.bytes())
					it.bind(2, note.body)
					it.bind(3, note.updatedAt)
					it.bind(4, if (note.deleted) 1L else 0L)
					it.bind(5, if (note.dirty) 1L else 0L)
					it.step()
				}
				Saved.InPlace
			}
		}
	}

	fun put(note: Note, pulled: Boolean) {
		connection.prepare(
			"""
			$INSERTION
			ON CONFLICT(uuid) DO UPDATE SET
				body = excluded.body,
				createdAt = excluded.createdAt,
				updatedAt = excluded.updatedAt,
				deleted = excluded.deleted,
				dirty = excluded.dirty,
				v = excluded.v,
				ext = excluded.ext,
				pulled = excluded.pulled
			""".trimIndent(),
		).use {
			bind(note, pulled, it)
			it.step()
		}
	}

	fun insertMissing(notes: List<Note>): List<Note> = connection.transaction {
		connection.prepare("$INSERTION ON CONFLICT(uuid) DO NOTHING RETURNING uuid").use { statement ->
			notes.filter { note ->
				bind(note, pulled = false, statement)
				statement.step().also { statement.reset() }
			}
		}
	}

	fun note(id: UUID): Note? = connection.prepare("SELECT $COLUMNS FROM note WHERE uuid = ?1").use {
		it.bind(1, id.bytes())
		if (it.step()) note(it) else null
	}

	fun liveNotes(): List<Note> = collect("SELECT $COLUMNS FROM note WHERE deleted = 0 ORDER BY updatedAt DESC")

	fun pendingPushes(): List<Note> = collect("SELECT $COLUMNS FROM note WHERE dirty = 1")

	fun search(text: String): List<Note> {
		val expression = matchExpression(text) ?: return emptyList()
		val columns = COLUMNS.split(", ").joinToString(", ") { "note.$it" }
		return collect(
			"""
			SELECT $columns
			FROM note JOIN note_fts ON note_fts.rowid = note.rowid
			WHERE note_fts MATCH ?1 AND note.deleted = 0
			ORDER BY rank
			""".trimIndent(),
		) { it.bind(1, expression) }
	}

	fun discardUnsynced(id: UUID, shownAt: Long, moment: Long) = connection.transaction {
		val neverPushed = connection.prepare("DELETE FROM note WHERE uuid = ?1 AND v = 0 RETURNING uuid").use {
			it.bind(1, id.bytes())
			it.step()
		}
		if (!neverPushed && !wasPulled(id, after = shownAt)) markDeleted(id, moment)
	}

	fun markDeleted(id: UUID, moment: Long) {
		connection.prepare(
			"""
			INSERT INTO note (uuid, body, createdAt, updatedAt, deleted, dirty, pulled) VALUES (?1, '', ?2, ?2, 1, 0, 0)
			ON CONFLICT(uuid) DO UPDATE SET deleted = 1, dirty = 1, body = '', ext = x'', updatedAt = ?2, pulled = 0
			""".trimIndent(),
		).use {
			it.bind(1, id.bytes())
			it.bind(2, moment)
			it.step()
		}
	}

	private fun wasPulled(id: UUID, after: Long) = connection.prepare("SELECT 1 FROM note WHERE uuid = ?1 AND pulled = 1 AND v != ?2").use {
		it.bind(1, id.bytes())
		it.bind(2, after)
		it.step()
	}

	private fun collect(sql: String, bind: (SQLiteStatement) -> Unit = {}): List<Note> = connection.prepare(sql).use {
		bind(it)
		buildList { while (it.step()) note(it)?.let(::add) }
	}

	companion object {
		const val COLUMNS = "uuid, body, createdAt, updatedAt, deleted, dirty, v, ext"
		private const val INSERTION = "INSERT INTO note ($COLUMNS, pulled) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)"

		fun matchExpression(text: String): String? {
			val tokens = text.split { !it.isTokenCharacter() }.filter { it.isNotEmpty() }
			val last = tokens.lastOrNull() ?: return null
			val phrases = tokens.joinToString(" ") { "\"${it.replace("\"", "\"\"")}\"" }
			return if (last.codePointCount(0, last.length) >= 2) "$phrases*" else phrases
		}

		private fun bind(note: Note, pulled: Boolean, statement: SQLiteStatement) {
			statement.bind(1, note.id.bytes())
			statement.bind(2, note.body)
			statement.bind(3, note.createdAt)
			statement.bind(4, note.updatedAt)
			statement.bind(5, if (note.deleted) 1L else 0L)
			statement.bind(6, if (note.dirty) 1L else 0L)
			statement.bind(7, note.v)
			statement.bind(8, note.ext)
			statement.bind(9, if (pulled) 1L else 0L)
		}

		private fun note(statement: SQLiteStatement): Note? {
			val id = statement.bytes(0).takeIf { it.size == 16 }?.let(::uuidOf) ?: return null
			return Note(
				id = id,
				body = statement.string(1),
				createdAt = statement.long(2),
				updatedAt = statement.long(3),
				deleted = statement.long(4) != 0L,
				dirty = statement.long(5) != 0L,
				v = statement.long(6),
				ext = statement.bytes(7),
			)
		}

		private fun Int.isTokenCharacter() = when (Character.getType(this).toByte()) {
			Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER, Character.MODIFIER_LETTER, Character.OTHER_LETTER,
			Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER,
			Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK,
			-> true
			else -> false
		}

		private fun String.split(isSeparator: (Int) -> Boolean): List<String> {
			val parts = mutableListOf<String>()
			val part = StringBuilder()
			codePoints().forEach { point ->
				if (isSeparator(point)) {
					parts += part.toString()
					part.clear()
				} else {
					part.appendCodePoint(point)
				}
			}
			return parts + part.toString()
		}
	}
}
