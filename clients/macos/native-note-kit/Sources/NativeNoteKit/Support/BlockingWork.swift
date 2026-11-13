import Foundation

nonisolated enum BlockingWork {
	private static let queue = DispatchQueue(label: "dev.hloth.nativenote.blocking", qos: .userInitiated)

	static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			queue.async { continuation.resume(with: Result(catching: work)) }
		}
	}
}
