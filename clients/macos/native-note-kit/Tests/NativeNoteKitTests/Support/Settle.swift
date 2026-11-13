import Foundation
import Testing

func settle(
	within limit: Duration = .seconds(30),
	sourceLocation: SourceLocation = #_sourceLocation,
	until done: () async throws -> Bool
) async throws {
	let deadline = ContinuousClock.now + limit
	var turns = 0
	while try await !done() {
		try Task.checkCancellation()
		guard ContinuousClock.now < deadline else {
			Issue.record("The awaited state was not reached within \(limit).", sourceLocation: sourceLocation)
			return
		}
		turns += 1
		if turns < 10_000 {
			await Task.yield()
		} else {
			try await Task.sleep(for: .milliseconds(5))
		}
	}
}

func staysTrue(
	for turns: Int = 10_000,
	sourceLocation: SourceLocation = #_sourceLocation,
	_ condition: () async throws -> Bool
) async rethrows {
	for _ in 0 ..< turns {
		guard try await condition() else {
			Issue.record("The state changed while it was expected to stay as it was.", sourceLocation: sourceLocation)
			return
		}
		await Task.yield()
	}
}
