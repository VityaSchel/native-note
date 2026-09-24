import Foundation

func settle(until done: () async throws -> Bool) async rethrows {
	for _ in 0 ..< 10_000 {
		if try await done() { return }
		await Task.yield()
	}
}
