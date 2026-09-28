import Foundation
import Testing

@testable import PowerLossKit

@MainActor private final class Connections {
	var opened = 0
	var released = 0
	private var peers: [Pipe] = []
	private var pending: [CheckedContinuation<AgentSession, any Error>] = []

	func silentSession() -> AgentSession {
		let replies = Pipe()
		let requests = Pipe()
		peers += [replies, requests]
		opened += 1
		return AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, release: { self.released += 1 })
	}

	func sessionThatNeverOpens() async throws -> AgentSession {
		try await withCheckedThrowingContinuation { pending.append($0) }
	}

	func openLate() {
		for continuation in pending {
			continuation.resume(returning: silentSession())
		}
		pending = []
	}
}

@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
	let deadline = ContinuousClock.now + .seconds(2)
	while !condition(), ContinuousClock.now < deadline {
		try? await Task.sleep(for: .milliseconds(10))
	}
	return condition()
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AgentReadinessTests {
	private let limit = Duration.seconds(1)
	private let margin = Duration.seconds(1)

	@Test func aPeerThatAcceptsButNeverAnswersIsGivenUpWithinTheLimit() async throws {
		let connections = Connections()
		let started = ContinuousClock.now

		await #expect(throws: AgentReadiness.Failure.silent(limit)) {
			try await AgentReadiness.wait(within: limit, attempt: .milliseconds(300), pause: .milliseconds(100), stopReason: { nil }) { connections.silentSession() }
		}

		#expect(ContinuousClock.now - started < limit + margin)
		#expect(connections.opened >= 1)
		#expect(await eventually { connections.released == connections.opened })
	}

	@Test func anOpenThatNeverReturnsIsGivenUpWithinTheLimitAndClosedWhenItDoes() async throws {
		let connections = Connections()
		let started = ContinuousClock.now

		await #expect(throws: AgentReadiness.Failure.silent(limit)) {
			try await AgentReadiness.wait(within: limit, attempt: .milliseconds(300), pause: .milliseconds(100), stopReason: { nil }) { try await connections.sessionThatNeverOpens() }
		}

		#expect(ContinuousClock.now - started < limit + margin)
		connections.openLate()
		#expect(connections.opened >= 1)
		#expect(await eventually { connections.released == connections.opened })
	}

	@Test func aStoppedMachineEndsTheWaitWithoutConnecting() async throws {
		let connections = Connections()

		await #expect(throws: AgentReadiness.Failure.stopped("the guest shut down")) {
			try await AgentReadiness.wait(within: limit, stopReason: { "the guest shut down" }) { connections.silentSession() }
		}

		#expect(connections.opened == 0)
	}
}
