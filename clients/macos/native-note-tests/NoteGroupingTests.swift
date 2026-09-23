import Foundation
import Testing

@testable import NativeNote

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
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SaveSchedulerTests {
	private let alarm = Alarm()

	private func scheduler() -> SaveScheduler {
		SaveScheduler(sleep: alarm.sleep)
	}

	@Test func coalescesABurstIntoOneSaveOfTheLatestEdit() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()

		for value in 0 ..< 5 {
			scheduler.schedule(id) { await saves.append(value) }
		}
		await ring(alarm)
		await settle { await !saves.values.isEmpty }

		#expect(await saves.values == [4])
	}

	@Test func keepsTheFirstDeadlineWhileEditsContinue() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()

		scheduler.schedule(id) { await saves.append(1) }
		scheduler.schedule(id) { await saves.append(2) }
		await ring(alarm)
		await settle { await saves.values == [2] }
		scheduler.schedule(id) { await saves.append(3) }
		await ring(alarm)
		await settle { await saves.values == [2, 3] }

		#expect(await alarm.started == 2)
		#expect(await saves.values == [2, 3])
	}

	@Test func savesForDifferentNotesDoNotCancelEachOther() async {
		let scheduler = scheduler()
		let saves = Log()

		scheduler.schedule(UUID()) { await saves.append(1) }
		scheduler.schedule(UUID()) { await saves.append(2) }
		await ring(alarm, whenSleeping: 2)
		await settle { await saves.values.count == 2 }

		#expect(await saves.values.sorted() == [1, 2])
	}

	@Test func flushWritesImmediatelyAndCancelsThePendingWrite() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()

		scheduler.schedule(id) { await saves.append(1) }
		#expect(await scheduler.flush(id))
		#expect(await saves.values == [1])

		#expect(await scheduler.flushAll())
		await settle { await alarm.sleeping == 0 }
		#expect(await saves.values == [1])
	}

	@Test func writesForOneNoteLandInOrder() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()
		let slowWrite = Alarm()

		scheduler.schedule(id) {
			_ = await saves.append(0)
			try? await slowWrite.sleep(for: .zero)
			return await saves.append(1)
		}
		let first = Task { await scheduler.flush(id) }
		await settle { await saves.values == [0] }
		scheduler.schedule(id) { await saves.append(2) }
		let second = Task { await scheduler.flush(id) }
		await ring(slowWrite)
		_ = await first.value
		_ = await second.value

		#expect(await saves.values == [0, 1, 2])
	}

	@Test func reportsAWriteThatFailed() async {
		let scheduler = scheduler()
		let failing = UUID()

		scheduler.schedule(failing) { false }
		scheduler.schedule(UUID()) { true }

		#expect(await scheduler.flushAll() == false)
		#expect(await scheduler.flush(failing))
	}

	@Test func flushAllGivesARequeuedWriteOneMoreTry() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()

		scheduler.schedule(id) {
			await scheduler.schedule(id) { await saves.append(2) }
			return false
		}

		#expect(await scheduler.flushAll())
		#expect(await saves.values == [2])
	}

	@Test func discardDropsThePendingWrite() async {
		let scheduler = scheduler()
		let saves = Log()
		let id = UUID()

		scheduler.schedule(id) { await saves.append(1) }
		await scheduler.discard(id)
		await scheduler.flushAll()

		#expect(await saves.values.isEmpty)
	}
}

private actor Log {
	private(set) var values: [Int] = []

	func append(_ value: Int) -> Bool {
		values.append(value)
		return true
	}
}
