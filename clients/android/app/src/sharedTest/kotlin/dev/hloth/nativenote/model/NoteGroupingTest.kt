package dev.hloth.nativenote.model

import dev.hloth.nativenote.storage.Note
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NoteGroupingTest {
	private val utc = ZoneId.of("UTC")
	private val now = moment(2026, 8, 14, 12)

	private fun moment(year: Int, month: Int, day: Int, hour: Int, zone: ZoneId = utc) =
		ZonedDateTime.of(year, month, day, hour, 0, 0, 0, zone).toInstant().toEpochMilli()

	private fun daysAgo(count: Long) = now - count * 86_400_000

	private fun grouping(now: Long = this.now, zone: ZoneId = utc, locale: Locale = Locale.UK, clock: String = "HH:mm") =
		NoteGrouping(
			now,
			zone,
			NoteGrouping.Words(
				today = "Today",
				yesterday = "Yesterday",
				previousWeek = "Previous 7 Days",
				dateAtTime = { day, time -> "$day at $time" },
				time = DateTimeFormatter.ofPattern(clock, locale),
				locale = locale,
			),
		)

	private fun note(body: String, at: Long) = Note(UUID.randomUUID(), body, at, at)

	@Test
	fun namesEachBucketByDistanceFromNow() {
		val grouping = grouping()
		assertEquals("Today", grouping.title(now))
		assertEquals("Yesterday", grouping.title(daysAgo(1)))
		assertEquals("Previous 7 Days", grouping.title(daysAgo(3)))
		assertEquals("July", grouping.title(daysAgo(30)))
		assertEquals("2025", grouping.title(daysAgo(400)))
	}

	@Test
	fun datesEachNoteByDistanceFromNow() {
		val grouping = grouping()
		assertEquals("Yesterday", grouping.dateLabel(daysAgo(1)))
		assertEquals("Tuesday", grouping.dateLabel(daysAgo(3)))
		assertEquals("Friday", grouping.dateLabel(daysAgo(7)))
		assertEquals("2026.08.06", grouping.dateLabel(daysAgo(8)))
		assertEquals("2026.07.15", grouping.dateLabel(daysAgo(30)))
		assertEquals("2025.07.10", grouping.dateLabel(daysAgo(400)))
	}

	@Test
	fun speaksAnOlderDateInWordsAndARecentOneAsShown() {
		val grouping = grouping()
		assertEquals("Yesterday", grouping.spokenDateLabel(daysAgo(1)))
		assertEquals("Tuesday", grouping.spokenDateLabel(daysAgo(3)))
		assertEquals("6 August 2026", grouping.spokenDateLabel(daysAgo(8)))
		assertEquals("10 July 2025", grouping.spokenDateLabel(daysAgo(400)))
	}

	@Test
	fun datesTodaysNotesByTheClockInTheGivenFormat() {
		val evening = moment(2026, 8, 14, 21)

		assertEquals("21:00", grouping(now = evening).dateLabel(evening))
		assertTrue(grouping(now = evening, locale = Locale.US, clock = "h:mm a").dateLabel(evening).endsWith("PM"))
	}

	@Test
	fun datesByTheTimeZone() {
		val tokyo = ZoneId.of("Asia/Tokyo")
		val lateYesterdayInUtc = moment(2026, 8, 14, 0) - 1_800_000
		val lastEveningOfJulyInUtc = moment(2026, 7, 31, 20)

		assertEquals("Yesterday", grouping().dateLabel(lateYesterdayInUtc))
		assertNotEquals("Yesterday", grouping(zone = tokyo).dateLabel(lateYesterdayInUtc))
		assertEquals("2026.07.31", grouping().dateLabel(lastEveningOfJulyInUtc))
		assertEquals("2026.08.01", grouping(zone = tokyo).dateLabel(lastEveningOfJulyInUtc))
	}

	@Test
	fun treatsTheSameDayAsTodayRegardlessOfClockTime() {
		assertEquals("Today", grouping().title(moment(2026, 8, 14, 1)))
	}

	@Test
	fun groupsNewestFirstAndKeepsOrderWithinABucket() {
		val notes = listOf(
			note("older today", moment(2026, 8, 14, 9)),
			note("last year", daysAgo(400)),
			note("newest today", now),
			note("yesterday", daysAgo(1)),
		)

		val groups = grouping().groups(notes)

		assertEquals(listOf("Today", "Yesterday", "2025"), groups.map { it.title })
		assertEquals(listOf("newest today", "older today"), groups[0].notes.map { it.body })
		assertEquals(listOf("yesterday"), groups[1].notes.map { it.body })
	}

	@Test
	fun producesNoGroupsForNoNotes() {
		assertEquals(emptyList<NoteGroup>(), grouping().groups(emptyList()))
	}

	@Test
	fun groupTitlesStayUniqueForAdversarialDates() {
		val now = System.currentTimeMillis()
		val offsets = listOf(-86_400L * 400, -86_400L * 40, -86_400L * 8, -86_400L * 3, -3_600, 0, 3_600, 86_400, 86_400L * 90)
		val notes = offsets.mapIndexed { index, offset -> note("note $index", now + offset * 1000) }

		val titles = grouping(now = now, zone = ZoneId.systemDefault()).groups(notes).map { it.title }

		assertEquals("duplicate section titles: $titles", titles.size, titles.toSet().size)
	}

	@Test
	fun theSevenDayBucketEndsAtTheStartOfTheDayAWeekAgo() {
		assertEquals("Previous 7 Days", grouping().title(daysAgo(7)))
		assertEquals("August", grouping().title(daysAgo(8)))
	}

	@Test
	fun lastWeekAcrossNewYearStaysInThePreviousSevenDays() {
		assertEquals("Previous 7 Days", grouping(now = moment(2027, 1, 2, 12)).title(moment(2026, 12, 30, 12)))
	}

	@Test
	fun aDaylightSavingDayStillStartsAtLocalMidnight() {
		val london = ZoneId.of("Europe/London")
		val afterTheClocksWentForward = moment(2026, 3, 29, 12, london)

		assertEquals("Today", grouping(now = afterTheClocksWentForward, zone = london).title(moment(2026, 3, 29, 0, london)))
		assertEquals("Yesterday", grouping(now = afterTheClocksWentForward, zone = london).title(moment(2026, 3, 28, 0, london)))
	}

	@Test
	fun anyPulledMomentGetsALabel() {
		val grouping = grouping()

		assertEquals("Today", grouping.title(Long.MAX_VALUE))
		assertTrue(grouping.title(Long.MIN_VALUE).isNotEmpty())
		assertTrue(grouping.dateLabel(Long.MIN_VALUE).isNotEmpty())
		assertTrue(grouping.dateLabel(Long.MAX_VALUE).isNotEmpty())
	}

	@Test
	fun theEditorDateLineIsTheListDateAndTheTime() {
		assertEquals("2026.08.06 at 10:22", grouping().editorDateLine(1_786_011_720_000))
	}

	@Test
	fun theEditorDateLineIsSpokenInWordsWithTheTime() {
		assertEquals("6 August 2026 at 10:22", grouping().spokenEditorDateLine(1_786_011_720_000))
	}
}
