@MainActor
final class Latch {
	private var waiting: [CheckedContinuation<Void, Never>] = []

	var isHolding: Bool {
		!waiting.isEmpty
	}

	func wait() async {
		await withCheckedContinuation { waiting.append($0) }
	}

	func release() {
		let released = waiting
		waiting = []
		released.forEach { $0.resume() }
	}
}
