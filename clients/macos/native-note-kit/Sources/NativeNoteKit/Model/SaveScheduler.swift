import Foundation

final class SaveScheduler {
	typealias Save = @Sendable () async -> Bool
	typealias Sleep = @Sendable (Duration) async throws -> Void

	private struct Pending {
		var save: Save
		let deadline: Task<Void, Never>
	}

	private let delay: Duration
	private let sleep: Sleep
	private var pending: [UUID: Pending] = [:]
	private var writing: [UUID: Task<Bool, Never>] = [:]

	init(delay: Duration = .milliseconds(300), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
		self.delay = delay
		self.sleep = sleep
	}

	func schedule(_ id: UUID, _ save: @escaping Save) {
		guard pending[id] == nil else {
			pending[id]?.save = save
			return
		}
		let deadline = Task { [delay, sleep] in
			try? await sleep(delay)
			guard !Task.isCancelled else { return }
			await flush(id)
		}
		pending[id] = Pending(save: save, deadline: deadline)
	}

	@discardableResult
	func flush(_ id: UUID) async -> Bool {
		if let due = pending.removeValue(forKey: id) {
			due.deadline.cancel()
			let previous = writing[id]
			writing[id] = Task {
				_ = await previous?.value
				return await due.save()
			}
		}
		guard let latest = writing[id] else { return true }
		let landed = await latest.value
		if writing[id] == latest { writing[id] = nil }
		return landed
	}

	@discardableResult
	func flushAll() async -> Bool {
		var landed = true
		for id in Set(pending.keys).union(writing.keys) {
			var saved = await flush(id)
			if !saved, pending[id] != nil {
				saved = await flush(id)
			}
			landed = saved && landed
		}
		return landed
	}

	func discard(_ id: UUID) async {
		pending.removeValue(forKey: id)?.deadline.cancel()
		await flush(id)
	}
}
