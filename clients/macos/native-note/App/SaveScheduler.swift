import Foundation

@MainActor final class SaveScheduler {
	private let debounce: Duration
	private var pending: Task<Void, Never>?

	init(debounce: Duration = .milliseconds(300)) {
		self.debounce = debounce
	}

	func schedule(_ save: @escaping @Sendable () async -> Void) {
		pending?.cancel()
		pending = Task {
			try? await Task.sleep(for: debounce)
			guard !Task.isCancelled else { return }
			await save()
		}
	}

	func flush(_ save: @escaping @Sendable () async -> Void) async {
		pending?.cancel()
		pending = nil
		await save()
	}
}
