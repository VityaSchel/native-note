import CryptoKit
import Foundation
import LocalAuthentication
import Synchronization

@testable import NativeNoteKit

final class FakeKeyStore: UnlockKeyStore {
	enum Reply: Sendable {
		case key
		case otherKey
		case miss
		case cancel
		case lockout
		case unavailable
		case failure
	}

	private struct State {
		var key: SymmetricKey?
		var reply = Reply.key
		var failsWrites = false
		var reasons: [String] = []
		var whileLoading: (@Sendable () async -> Void)?
		var availability: BiometricAvailability
	}

	private let state: Mutex<State>
	nonisolated(unsafe) private var askedThrough: [LAContext] = []

	init(available: Bool = true) {
		state = Mutex(State(availability: available ? .available : .unavailable))
	}

	var storedKey: SymmetricKey? { state.withLock { $0.key } }

	var reasons: [String] { state.withLock { $0.reasons } }

	@MainActor var contexts: [LAContext] { askedThrough }

	func whileLoading(_ body: @escaping @Sendable () async -> Void) {
		state.withLock { $0.whileLoading = body }
	}

	func reply(with reply: Reply) {
		state.withLock { $0.reply = reply }
	}

	func becomes(_ availability: BiometricAvailability) {
		state.withLock { $0.availability = availability }
	}

	@MainActor func forgetReads() {
		askedThrough = []
		state.withLock { $0.reasons = [] }
	}

	func failWrites() {
		state.withLock { $0.failsWrites = true }
	}

	func plant(_ key: SymmetricKey) {
		state.withLock { $0.key = key }
	}

	var availability: BiometricAvailability { state.withLock { $0.availability } }

	func hasKey() -> Bool { storedKey != nil }

	func save(_ key: SymmetricKey) throws {
		try state.withLock {
			guard !$0.failsWrites else { throw KeychainFailure(status: errSecNotAvailable) }
			$0.key = key
		}
	}

	func read(through context: LAContext, reason: String) async throws -> StoredKeyRead {
		askedThrough.append(context)
		let hook = state.withLock {
			$0.reasons.append(reason)
			return $0.whileLoading
		}
		await hook?()
		let (key, reply) = state.withLock { ($0.key, $0.reply) }
		switch reply {
		case .key:
			guard let key else { throw KeychainFailure(status: errSecItemNotFound) }
			return .key(key)
		case .otherKey: return .key(SymmetricKey(data: Data(repeating: 0xEE, count: 32)))
		case .miss: return .missed
		case .cancel: return .cancelled
		case .lockout: return .lockedOut
		case .unavailable: return .unavailable
		case .failure: throw KeychainFailure(status: errSecItemNotFound)
		}
	}

	func delete() throws {
		try state.withLock {
			guard !$0.failsWrites else { throw KeychainFailure(status: errSecNotAvailable) }
			$0.key = nil
		}
	}
}
