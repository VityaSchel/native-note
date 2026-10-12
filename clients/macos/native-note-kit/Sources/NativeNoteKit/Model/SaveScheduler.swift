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
	private var discarding = false
	private var holds = 0

	init(delay: Duration = .milliseconds(300), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
		self.delay = delay
		self.sleep = sleep
	}

	func schedule(_ id: UUID, _ save: @escaping Save) {
		guard !discarding else { return }
		guard pending[id] == nil else {
			pending[id]?.save = save
			return
		}
		let deadline = Task { [delay, sleep] in
			try? await sleep(delay)
			guard !Task.isCancelled, holds == 0 else { return }
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

	func isPending(_ id: UUID) -> Bool {
		pending[id] != nil
	}

	/// Keeps saves that fall due from landing until every hold is released, so a sync applies with none landing under it.
	func hold() {
		holds += 1
	}

	func release() {
		holds -= 1
		guard holds == 0 else { return }
		Task { await flushAll() }
	}

	func cancel(_ id: UUID) {
		pending.removeValue(forKey: id)?.deadline.cancel()
	}

	func discard(_ id: UUID) async {
		pending.removeValue(forKey: id)?.deadline.cancel()
		await flush(id)
	}

	func discardAll() async {
		discarding = true
		defer { discarding = false }
		for due in pending.values { due.deadline.cancel() }
		pending = [:]
		for task in writing.values { _ = await task.value }
		writing = [:]
	}
}
