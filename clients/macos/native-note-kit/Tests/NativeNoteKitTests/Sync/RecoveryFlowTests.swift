import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

/// A put whose answer is lost or replaced after it reached the server, per clients/DESIGN.md § Recovery flow.
struct RecoveryFlowTests {
	private struct Unreachable: SyncTransport {
		let attempts = Counter()

		func post(_ body: Data) async throws -> Data {
			attempts.increment()
			throw URLError(.cannotConnectToHost)
		}
	}

	private final class Counter: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0
		var value: Int { lock.withLock { count } }
		func increment() { lock.withLock { count += 1 } }
	}

	/// Each attempt reaches the scripted server or not, and loses its answer or not, as the script says.
	private final class StagedTransport: SyncTransport, @unchecked Sendable {
		enum Stage {
			case delivered
			case deliveredThenLost
			case unreachable
		}

		private let server: ScriptedServer
		private let lock = NSLock()
		private var stages: [Stage]

		init(_ server: ScriptedServer, _ stages: [Stage]) {
			self.server = server
			self.stages = stages
		}

		func post(_ body: Data) async throws -> Data {
			let stage = lock.withLock { stages.isEmpty ? .delivered : stages.removeFirst() }
			switch stage {
			case .delivered: return try await server.post(body)
			case .deliveredThenLost:
				_ = try await server.post(body)
				throw URLError(.networkConnectionLost)
			case .unreachable: throw URLError(.cannotConnectToHost)
			}
		}
	}

	private let recoveryKey = SymmetricKey(size: .bits256)

	private func flow(_ server: ScriptedServer, _ stages: [StagedTransport.Stage]) -> RecoveryFlow {
		RecoveryFlow(connection: SyncConnection(apiKey: server.apiKey, transport: StagedTransport(server, stages)))
	}

	@Test func aPutWhoseFirstAttemptMayHaveLandedIsCheckedThoughItsRetriesCannotConnect() async throws {
		let server = ScriptedServer()
		server.answer { _ in .put(status: .accepted, v: 4) }
		server.answer { [unowned server] _ in .get(v: 4, blob: putBlob(server)) }

		#expect(try await flow(server, [.deliveredThenLost, .unreachable, .unreachable]).put(sharedContentKey, under: recoveryKey, pin: 3) == 4)
	}

	@Test func aPutWhoseFirstAttemptMayHaveLandedAndWhoseCheckCannotConnectIsUnknown() async throws {
		let server = ScriptedServer()
		server.answer { _ in .put(status: .accepted, v: 4) }

		await #expect(throws: RecoveryFlow.Failure.outcomeUnknown) {
			try await flow(server, [.deliveredThenLost, .unreachable, .unreachable, .unreachable, .unreachable, .unreachable]).put(sharedContentKey, under: recoveryKey, pin: 3)
		}
	}

	@Test func aConflictWhoseCheckFailsIsUnknownRatherThanTheReadsError() async throws {
		let server = ScriptedServer()
		server.answer { _ in .put(status: .conflict, v: 4) }
		server.refuse()

		await #expect(throws: RecoveryFlow.Failure.outcomeUnknown) { try await flow(server).put(sharedContentKey, under: recoveryKey, pin: 3) }
	}

	private func flow(_ server: ScriptedServer) -> RecoveryFlow {
		RecoveryFlow(connection: SyncConnection(apiKey: server.apiKey, transport: server))
	}

	private func putBlob(_ server: ScriptedServer) -> Data {
		server.requests.compactMap { if case let .put(_, blob) = $0 { blob } else { nil } }.last ?? Data()
	}

	@Test func aPutThatLandedBehindAReplacedReplyIsRecognizedByItsBlob() async throws {
		let server = ScriptedServer()
		server.refuse()
		server.answer { [unowned server] _ in .get(v: 4, blob: putBlob(server)) }

		#expect(try await flow(server).put(sharedContentKey, under: recoveryKey, pin: 3) == 4)
		#expect(server.requests.count == 2)
	}

	@Test func aPutThatDidNotLandReportsTheFailureItGot() async throws {
		let server = ScriptedServer()
		let held = try RecoveryBlob.seal(sharedContentKey, under: SymmetricKey(size: .bits256))
		server.refuse(status: 400)
		server.answer { _ in .get(v: 3, blob: held) }

		await #expect(throws: SyncError.refused(status: 400)) { try await flow(server).put(sharedContentKey, under: recoveryKey, pin: 3) }
	}

	@Test func aReplacedReplyOverABlobAnotherDevicePutIsARotationElsewhere() async throws {
		let server = ScriptedServer()
		let other = try RecoveryBlob.seal(sharedContentKey, under: SymmetricKey(size: .bits256))
		server.refuse()
		server.answer { _ in .get(v: 5, blob: other) }

		await #expect(throws: RecoveryFlow.Failure.rotatedElsewhere) { try await flow(server).put(sharedContentKey, under: recoveryKey, pin: 3) }
	}

	@Test func aReplacedReplyWhoseCheckFailsTooLeavesTheOutcomeUnknown() async throws {
		let server = ScriptedServer()
		server.refuse()
		server.refuse()

		await #expect(throws: RecoveryFlow.Failure.outcomeUnknown) { try await flow(server).put(sharedContentKey, under: recoveryKey, pin: 3) }
	}

	@Test func aServerThatCouldNotBeReachedIsNotAskedAgain() async throws {
		let transport = Unreachable()
		let flow = RecoveryFlow(connection: SyncConnection(apiKey: SymmetricKey(size: .bits256), transport: transport))

		await #expect(throws: URLError(.cannotConnectToHost)) { try await flow.put(sharedContentKey, under: recoveryKey, pin: 0) }
		#expect(transport.attempts.value == 3)
	}
}
