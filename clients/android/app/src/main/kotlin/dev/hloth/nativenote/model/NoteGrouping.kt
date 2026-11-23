package dev.hloth.nativenote.model

import dev.hloth.nativenote.storage.Note
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.util.Locale

data class NoteGroup(val title: String, val notes: List<Note>)

class NoteGrouping(now: Long, private val zone: ZoneId, private val words: Words) {
	class Words(
		val today: String,
		val yesterday: String,
		val previousWeek: String,
		val dateAtTime: (day: String, time: String) -> String,
		val time: DateTimeFormatter,
		val locale: Locale,
	)

	private enum class Bucket { Today, Yesterday, PreviousWeek, ThisYear, Earlier }

	private val today: Long
	private val yesterday: Long
	private val weekAgo: Long
	private val year: Int

	init {
		val day = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
		today = day.atStartOfDay(zone).toInstant().toEpochMilli()
		yesterday = day.minusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
		weekAgo = day.minusDays(7).atStartOfDay(zone).toInstant().toEpochMilli()
		year = day.year
	}

	fun groups(notes: List<Note>): List<NoteGroup> {
		val grouped = mutableListOf<Pair<String, MutableList<Note>>>()
		for (note in notes.sortedByDescending { it.updatedAt }) {
			val title = title(note.updatedAt)
			if (grouped.lastOrNull()?.first == title) grouped.last().second += note else grouped += title to mutableListOf(note)
		}
		return grouped.map { (title, notes) -> NoteGroup(title, notes) }
	}

	fun title(moment: Long): String = when (bucket(moment)) {
		Bucket.Today -> words.today
		Bucket.Yesterday -> words.yesterday
		Bucket.PreviousWeek -> words.previousWeek
		Bucket.ThisYear -> date(moment).month.getDisplayName(TextStyle.FULL, words.locale)
		Bucket.Earlier -> date(moment).year.toString()
	}

	fun dateLabel(moment: Long): String = when (bucket(moment)) {
		Bucket.Today -> time(moment)
		Bucket.Yesterday -> words.yesterday
		Bucket.PreviousWeek -> date(moment).dayOfWeek.getDisplayName(TextStyle.FULL_STANDALONE, words.locale)
		Bucket.ThisYear, Bucket.Earlier -> day(moment)
	}

	fun spokenDateLabel(moment: Long): String = when (bucket(moment)) {
		Bucket.ThisYear, Bucket.Earlier -> DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(words.locale).format(date(moment))
		else -> dateLabel(moment)
	}

	fun editorDateLine(moment: Long): String = words.dateAtTime(day(moment), time(moment))

	fun spokenEditorDateLine(moment: Long): String = words.dateAtTime(
		DateTimeFormatter.ofLocalizedDate(FormatStyle.LONG).withLocale(words.locale).format(date(moment)),
		time(moment),
	)

	private fun bucket(moment: Long) = when {
		moment >= today -> Bucket.Today
		moment >= yesterday -> Bucket.Yesterday
		moment >= weekAgo -> Bucket.PreviousWeek
		date(moment).year == year -> Bucket.ThisYear
		else -> Bucket.Earlier
	}

	private fun date(moment: Long) = Instant.ofEpochMilli(moment).atZone(zone)

	private fun day(moment: Long) = DAY.format(date(moment))

	private fun time(moment: Long) = words.time.format(date(moment))

	private companion object {
		val DAY: DateTimeFormatter = DateTimeFormatter.ofPattern("y.MM.dd", Locale.ROOT)
	}
}
