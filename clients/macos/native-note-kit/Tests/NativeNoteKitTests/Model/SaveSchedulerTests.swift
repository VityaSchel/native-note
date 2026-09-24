import Foundation
import Testing

@testable import NativeNoteKit

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

	@Test func theDefaultSleepFiresTheSave() async {
		let scheduler = SaveScheduler(delay: .milliseconds(10))
		let saves = Log()

		scheduler.schedule(UUID()) { await saves.append(1) }
		for _ in 0 ..< 100 {
			if await !saves.values.isEmpty { break }
			try? await Task.sleep(for: .milliseconds(10))
		}

		#expect(await saves.values == [1])
	}
}

private actor Log {
	private(set) var values: [Int] = []

	func append(_ value: Int) -> Bool {
		values.append(value)
		return true
	}
}
