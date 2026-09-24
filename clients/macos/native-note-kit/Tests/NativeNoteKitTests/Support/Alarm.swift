import Foundation

@testable import NativeNoteKit

actor Alarm {
	private struct Sleeper {
		let number: Int
		let continuation: CheckedContinuation<Void, Never>
	}

	private(set) var started = 0
	private var sleepers: [Sleeper] = []

	var sleeping: Int { sleepers.count }

	nonisolated var sleep: SaveScheduler.Sleep {
		{ try await self.sleep(for: $0) }
	}

	func sleep(for _: Duration) async throws {
		started += 1
		let number = started
		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				if Task.isCancelled {
					continuation.resume()
				} else {
					sleepers.append(Sleeper(number: number, continuation: continuation))
				}
			}
		} onCancel: {
			Task { await self.ring(number: number) }
		}
		try Task.checkCancellation()
	}

	func ring() {
		let ringing = sleepers
		sleepers = []
		ringing.forEach { $0.continuation.resume() }
	}

	func ring(number: Int) {
		guard let index = sleepers.firstIndex(where: { $0.number == number }) else { return }
		sleepers.remove(at: index).continuation.resume()
	}
}

func ring(_ alarm: Alarm, whenSleeping count: Int = 1) async {
	await settle { await alarm.sleeping >= count }
	await alarm.ring()
}
