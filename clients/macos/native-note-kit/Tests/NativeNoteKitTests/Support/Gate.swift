import Foundation
import Synchronization
import Testing

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

	func untilHolding(sourceLocation: SourceLocation = #_sourceLocation) async throws {
		try await settle(sourceLocation: sourceLocation) { isHolding }
	}
}
