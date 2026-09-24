import Foundation
import Testing

@testable import NativeNoteKit

private let calendar: Calendar = {
	var calendar = Calendar(identifier: .gregorian)
	calendar.timeZone = TimeZone(identifier: "UTC")!
	calendar.locale = Locale(identifier: "en_US_POSIX")
	return calendar
}()

private let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!

private func daysAgo(_ count: Int) -> Date {
	calendar.date(byAdding: .day, value: -count, to: now)!
}

private func today(hour: Int) -> Date {
	calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: hour))!
}

private func note(_ body: String, at moment: Date) -> Note {
	Note(id: UUID(), body: body, createdAt: moment, updatedAt: moment)
}

struct NoteGroupingTests {
	@Test func namesEachBucketByDistanceFromNow() {
		#expect(NoteGrouping.title(for: now, now: now, calendar: calendar) == "Today")
		#expect(NoteGrouping.title(for: daysAgo(1), now: now, calendar: calendar) == "Yesterday")
		#expect(NoteGrouping.title(for: daysAgo(3), now: now, calendar: calendar) == "Previous 7 days")
		#expect(NoteGrouping.title(for: daysAgo(30), now: now, calendar: calendar) == "July")
		#expect(NoteGrouping.title(for: daysAgo(400), now: now, calendar: calendar) == "2025")
	}

	@Test func treatsTheSameDayAsTodayRegardlessOfClockTime() {
		let earlier = today(hour: 1)

		#expect(NoteGrouping.title(for: earlier, now: now, calendar: calendar) == "Today")
	}

	@Test func groupsNewestFirstAndKeepsOrderWithinABucket() {
		let notes = [
			note("older today", at: today(hour: 9)),
			note("last year", at: daysAgo(400)),
			note("newest today", at: now),
			note("yesterday", at: daysAgo(1)),
		]

		let groups = NoteGrouping.groups(for: notes, now: now, calendar: calendar)

		#expect(groups.map(\.title) == ["Today", "Yesterday", "2025"])
		#expect(groups[0].notes.map(\.body) == ["newest today", "older today"])
		#expect(groups[1].notes.map(\.body) == ["yesterday"])
	}

	@Test func producesNoGroupsForNoNotes() {
		#expect(NoteGrouping.groups(for: [], now: now, calendar: calendar).isEmpty)
	}

	@Test func groupTitlesStayUniqueForAdversarialDates() {
		let calendar = Calendar(identifier: .gregorian)
		let now = Date()
		let offsets = [-86_400 * 400, -86_400 * 40, -86_400 * 8, -86_400 * 3, -3_600, 0, 3_600, 86_400, 86_400 * 90]
		let notes = offsets.enumerated().map { index, offset in
			note("note \(index)", at: now.addingTimeInterval(Double(offset)))
		}

		let titles = NoteGrouping.groups(for: notes, now: now, calendar: calendar).map(\.title)

		#expect(Set(titles).count == titles.count, "duplicate section titles: \(titles)")
	}

	@Test func theSevenDayBucketEndsAtTheStartOfTheDayAWeekAgo() {
		#expect(NoteGrouping.title(for: daysAgo(7), now: now, calendar: calendar) == "Previous 7 days")
		#expect(NoteGrouping.title(for: daysAgo(8), now: now, calendar: calendar) == "August")
	}

	@Test func lastWeekAcrossNewYearStaysInThePreviousSevenDays() throws {
		let newYear = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 2, hour: 12)))
		let lastYear = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 12)))

		#expect(NoteGrouping.title(for: lastYear, now: newYear, calendar: calendar) == "Previous 7 days")
	}
}
