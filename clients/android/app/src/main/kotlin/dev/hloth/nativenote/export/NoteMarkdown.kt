package dev.hloth.nativenote.export

import dev.hloth.nativenote.storage.Note
import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale
import java.util.UUID

object NoteMarkdown {
	sealed class Failure(message: String) : Exception(message) {
		class NoFrontMatter : Failure("no front matter")

		class MissingField(field: String) : Failure("missing $field")

		class InvalidField(field: String) : Failure("invalid $field")

		class DuplicateField(field: String) : Failure("duplicate $field")

		class UnknownField(field: String) : Failure("unknown field $field")

		class MisplacedField(field: String) : Failure("misplaced $field")
	}

	private enum class Field(val key: String) {
		Id("id"),
		Created("created"),
		Updated("updated"),
	}

	private const val DELIMITER = "---"
	private const val UNTITLED = "Untitled"
	private const val FILE_EXTENSION = ".md"
	private const val FILE_NAME_BYTE_LIMIT = 254
	private const val NAME_BYTE_LIMIT = FILE_NAME_BYTE_LIMIT - 3 - 3
	private val SEPARATORS = "/\\:|".codePoints().toArray().toSet()
	private val REMOVED = "*?\"<>".codePoints().toArray().toSet()
	private val RESERVED_ON_WINDOWS = listOf("CON", "PRN", "AUX", "NUL") + listOf("COM", "LPT").flatMap { device -> "0123456789¹²³".map { "$device$it" } }

	fun render(note: Note): String {
		val fields = Field.entries.joinToString("") { "${it.key}: ${value(it, note)}\n" }
		return "$DELIMITER\n$fields$DELIMITER\n${note.body}"
	}

	fun parse(text: String): Note {
		val (lines, body) = frontMatter(text)
		val values = fieldValues(lines)
		return Note(
			id = decode(Field.Id, values, { runCatching { UUID.fromString(it) }.getOrNull() }, { it.toString() }),
			body = body,
			createdAt = decode(Field.Created, values, Timestamp::milliseconds, Timestamp::string),
			updatedAt = decode(Field.Updated, values, Timestamp::milliseconds, Timestamp::string),
			dirty = true,
		)
	}

	fun fileNames(notes: List<Note>): List<String> {
		val names = notes.map { name(it.title) }
		val claimOrder = notes.indices.sortedWith(compareBy({ notes[it].createdAt }, { notes[it].id.toString() }, { it }))
		val claimed = HashSet<String>()
		val clashing = claimOrder.filter { !claimed.add(collisionKey(names[it])) }
		val unique = names.toMutableList()
		val nextNumber = HashMap<String, Int>()
		for (index in clashing) {
			val key = collisionKey(names[index])
			var number = nextNumber[key] ?: 2
			var candidate = numbered(names[index], number)
			while (!claimed.add(collisionKey(candidate))) candidate = numbered(names[index], ++number)
			nextNumber[key] = number + 1
			unique[index] = candidate
		}
		return unique.map { it + FILE_EXTENSION }
	}

	private fun name(title: String): String {
		val replaced = StringBuilder()
		title.codePoints().forEach { point ->
			when {
				point in REMOVED -> Unit
				point in SEPARATORS -> replaced.append('-')
				Character.getType(point) == Character.CONTROL.toInt() -> replaced.append(' ')
				else -> replaced.appendCodePoint(point)
			}
		}
		val name = fitted(Normalizer.normalize(replaced, Normalizer.Form.NFC).trim(::isTrimmable), NAME_BYTE_LIMIT)
		return if (isReservedOnWindows(name)) fitted("_$name", NAME_BYTE_LIMIT) else name
	}

	private fun isReservedOnWindows(name: String) =
		name.substringBefore('.').trim { it == ' ' || it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }.uppercase(Locale.ROOT) in RESERVED_ON_WINDOWS

	private fun numbered(name: String, number: Int): String {
		val suffix = " $number"
		return fitted(name, FILE_NAME_BYTE_LIMIT - FILE_EXTENSION.length - suffix.length) + suffix
	}

	private fun fitted(name: String, byteLimit: Int): String {
		val clusters = BreakIterator.getCharacterInstance(Locale.ROOT).apply { setText(name) }
		var bytes = 0
		var end = 0
		var next = clusters.next()
		while (next != BreakIterator.DONE) {
			bytes += name.substring(end, next).encodeToByteArray().size
			if (bytes > byteLimit) break
			end = next
			next = clusters.next()
		}
		return name.substring(0, end).trim(::isTrimmable).ifEmpty { UNTITLED }
	}

	private fun collisionKey(name: String): String {
		val decomposed = Normalizer.normalize(name, Normalizer.Form.NFD)
		return Normalizer.normalize(decomposed.uppercase(Locale.ROOT).lowercase(Locale.ROOT), Normalizer.Form.NFD)
	}

	private fun isTrimmable(character: Char) = character == '.' || character in '\t'..'\r' || character == '\u0085' ||
		when (Character.getType(character).toByte()) {
			Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
			else -> false
		}

	private fun value(field: Field, note: Note) = when (field) {
		Field.Id -> note.id.toString()
		Field.Created -> Timestamp.string(note.createdAt)
		Field.Updated -> Timestamp.string(note.updatedAt)
	}

	private fun frontMatter(text: String): Pair<List<String>, String> {
		val opening = "$DELIMITER\n"
		if (!text.startsWith(opening)) throw Failure.NoFrontMatter()
		val lines = mutableListOf<String>()
		var lineStart = opening.length
		while (true) {
			val lineEnd = text.indexOf('\n', lineStart)
			if (lineEnd < 0) throw Failure.NoFrontMatter()
			val line = text.substring(lineStart, lineEnd)
			lineStart = lineEnd + 1
			if (line == DELIMITER) return lines to text.substring(lineStart)
			lines += line
		}
	}

	private fun fieldValues(lines: List<String>): Map<Field, String> {
		val values = mutableMapOf<Field, String>()
		var expected = Field.entries.toList()
		for (line in lines) {
			val name = line.substringBefore(':')
			val field = Field.entries.firstOrNull { it.key == name } ?: throw Failure.UnknownField(name)
			if (field in values) throw Failure.DuplicateField(field.key)
			val position = expected.indexOf(field)
			if (position < 0) throw Failure.MisplacedField(field.key)
			val prefix = "${field.key}: "
			if (!line.startsWith(prefix)) throw Failure.InvalidField(field.key)
			expected = expected.drop(position + 1)
			values[field] = line.removePrefix(prefix)
		}
		return values
	}

	private fun <T> decode(field: Field, values: Map<Field, String>, parse: (String) -> T?, render: (T) -> String): T {
		val text = values[field] ?: throw Failure.MissingField(field.key)
		val value = parse(text)
		if (value == null || render(value) != text) throw Failure.InvalidField(field.key)
		return value
	}

	private object Timestamp {
		private const val MILLISECONDS_PER_DAY = 86_400_000L
		private const val DAYS_PER_ERA = 146_097L
		private const val DAYS_FROM_ERA_START_TO_EPOCH = 719_468L
		private const val LAYOUT_AFTER_YEAR = "-MM-DDTHH:mm:ss.sssZ"
		private val signedYearLengths = 7..10

		fun string(milliseconds: Long): String {
			val days = Math.floorDiv(milliseconds, MILLISECONDS_PER_DAY)
			val time = Math.floorMod(milliseconds, MILLISECONDS_PER_DAY)
			val (year, month, day) = civilDate(days)
			val yearText = if (year in 0..9999) padded(year, 4) else (if (year < 0) "-" else "+") + padded(Math.absExact(year), 6)
			val clock = "${padded(time / 3_600_000, 2)}:${padded(time / 60_000 % 60, 2)}:${padded(time / 1000 % 60, 2)}"
			return "$yearText-${padded(month, 2)}-${padded(day, 2)}T$clock.${padded(time % 1000, 3)}Z"
		}

		fun milliseconds(text: String): Long? {
			val yearEnd = text.length - LAYOUT_AFTER_YEAR.length
			val signed = yearEnd in signedYearLengths
			if (yearEnd != 4 && !signed) return null
			val magnitude = decimal(text, if (signed) 1 else 0, yearEnd) ?: return null
			val month = decimal(text, yearEnd + 1, yearEnd + 3) ?: return null
			val day = decimal(text, yearEnd + 4, yearEnd + 6) ?: return null
			val hour = decimal(text, yearEnd + 7, yearEnd + 9) ?: return null
			val minute = decimal(text, yearEnd + 10, yearEnd + 12) ?: return null
			val second = decimal(text, yearEnd + 13, yearEnd + 15) ?: return null
			val millisecond = decimal(text, yearEnd + 16, yearEnd + 19) ?: return null
			val year = if (text.startsWith('-')) -magnitude else magnitude
			val time = ((hour * 60 + minute) * 60 + second) * 1000 + millisecond
			return try {
				Math.addExact(Math.multiplyExact(days(year, month, day), MILLISECONDS_PER_DAY), time)
			} catch (_: ArithmeticException) {
				null
			}
		}

		private fun decimal(text: String, start: Int, end: Int): Long? {
			var value = 0L
			for (index in start until end) {
				val digit = text[index]
				if (digit !in '0'..'9') return null
				value = value * 10 + (digit - '0')
			}
			return value
		}

		private fun padded(number: Long, width: Int) = number.toString().padStart(width, '0')

		private fun days(year: Long, month: Long, day: Long): Long {
			val marchYear = if (month <= 2) year - 1 else year
			val era = (if (marchYear >= 0) marchYear else marchYear - 399) / 400
			val yearOfEra = marchYear - era * 400
			val dayOfYear = (153 * (if (month > 2) month - 3 else month + 9) + 2) / 5 + day - 1
			val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
			return era * DAYS_PER_ERA + dayOfEra - DAYS_FROM_ERA_START_TO_EPOCH
		}

		private fun civilDate(days: Long): Triple<Long, Long, Long> {
			val shifted = days + DAYS_FROM_ERA_START_TO_EPOCH
			val era = (if (shifted >= 0) shifted else shifted - 146_096) / DAYS_PER_ERA
			val dayOfEra = shifted - era * DAYS_PER_ERA
			val yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
			val dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
			val marchMonth = (5 * dayOfYear + 2) / 153
			val month = if (marchMonth < 10) marchMonth + 3 else marchMonth - 9
			val day = dayOfYear - (153 * marchMonth + 2) / 5 + 1
			return Triple(yearOfEra + era * 400 + if (month <= 2) 1 else 0, month, day)
		}
	}
}
