public struct TimeLimitExceeded: Error, Equatable, CustomStringConvertible {
	public let limit: Duration

	public var description: String {
		"nothing within \(limit)"
	}
}

@MainActor private final class Race<T: Sendable> {
	private var continuation: CheckedContinuation<T, any Error>?
	private let discardLate: (T) -> Void
	var timer: Task<Void, Never>?

	init(_ continuation: CheckedContinuation<T, any Error>, discardLate: @escaping (T) -> Void) {
		self.continuation = continuation
		self.discardLate = discardLate
	}

	func finish(_ result: Result<T, any Error>) {
		timer?.cancel()
		guard let continuation else {
			if case .success(let late) = result { discardLate(late) }
			return
		}
		self.continuation = nil
		continuation.resume(with: result)
	}
}

@MainActor public func withTimeLimit<T: Sendable>(_ limit: Duration, discardingLate discardLate: @escaping (T) -> Void = { _ in }, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
	try await withCheckedThrowingContinuation { continuation in
		let race = Race(continuation, discardLate: discardLate)
		let work = Task {
			do {
				race.finish(.success(try await operation()))
			} catch {
				race.finish(.failure(error))
			}
		}
		race.timer = Task {
			guard (try? await Task.sleep(for: limit)) != nil else { return }
			work.cancel()
			race.finish(.failure(TimeLimitExceeded(limit: limit)))
		}
	}
}
