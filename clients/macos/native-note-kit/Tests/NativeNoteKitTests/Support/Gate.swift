import Foundation
import Synchronization

final class Gate: Sendable {
	private let entered = Mutex(false)
	private let release = DispatchSemaphore(value: 0)

	var isHolding: Bool { entered.withLock { $0 } }

	func hold() {
		entered.withLock { $0 = true }
		release.wait()
	}

	func open() {
		release.signal()
	}

	func untilHolding() async throws {
		for _ in 0 ..< 2_000 where !isHolding {
			try await Task.sleep(for: .milliseconds(5))
		}
	}
}
