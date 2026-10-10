@MainActor public enum AgentReadiness {
	public enum Failure: Error, Equatable, CustomStringConvertible {
		case stopped(String)
		case silent(Duration)

		public var description: String {
			switch self {
			case .stopped(let reason): "the VM stopped while booting: \(reason)"
			case .silent(let limit): "the guest agent did not answer within \(limit)"
			}
		}
	}

	public static func wait(within limit: Duration, attempt: Duration = .seconds(10), pause: Duration = .seconds(2), stopReason: () -> String?, open: @escaping @MainActor () async throws -> AgentSession) async throws(Failure) {
		let deadline = ContinuousClock.now + limit
		while ContinuousClock.now < deadline {
			if let reason = stopReason() { throw .stopped(reason) }
			if await answers(before: min(deadline, .now + attempt), open) { return }
			try? await Task.sleep(until: min(deadline, .now + pause))
		}
		throw .silent(limit)
	}

	private static func answers(before deadline: ContinuousClock.Instant, _ open: @escaping @MainActor () async throws -> AgentSession) async -> Bool {
		guard let session = try? await withTimeLimit(deadline - .now, discardingLate: { $0.close() }, open) else { return false }
		defer { session.close() }
		return await session.wait(within: deadline - .now) { session.replies.contains(.ready) }
	}
}
