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

	static let keyMissing = KeychainFailure(status: errSecItemNotFound)
	static let readFailed = KeychainFailure(status: errSecInteractionNotAllowed)

	private struct Asked: @unchecked Sendable {
		let context: LAContext
	}

	private struct State {
		var key: SymmetricKey?
		var reply = Reply.key
		var failsWrites = false
		var reasons: [String] = []
		var asked: [Asked] = []
		var whileLoading: (@Sendable () async -> Void)?
		var whileDeleting: (@Sendable () -> Void)?
		var availability: BiometricAvailability
		var enrollment = Data([1])
		var keyEnrollment: Data?
	}

	private let state: Mutex<State>

	init(available: Bool = true) {
		state = Mutex(State(availability: available ? .available : .unavailable))
	}

	var storedKey: SymmetricKey? { state.withLock { $0.key } }

	var reasons: [String] { state.withLock { $0.reasons } }

	var contexts: [LAContext] { state.withLock { $0.asked }.map(\.context) }

	func whileLoading(_ body: @escaping @Sendable () async -> Void) {
		state.withLock { $0.whileLoading = body }
	}

	func whileDeleting(_ body: @escaping @Sendable () -> Void) {
		state.withLock { $0.whileDeleting = body }
	}

	func reply(with reply: Reply) {
		state.withLock { $0.reply = reply }
	}

	func becomes(_ availability: BiometricAvailability) {
		state.withLock { $0.availability = availability }
	}

	func forgetReads() {
		state.withLock {
			$0.asked = []
			$0.reasons = []
		}
	}

	func changeEnrollment() {
		state.withLock { $0.enrollment.append(1) }
	}

	func failWrites() {
		state.withLock { $0.failsWrites = true }
	}

	func plant(_ key: SymmetricKey) {
		state.withLock { $0.key = key }
	}

	var availability: BiometricAvailability { state.withLock { $0.availability } }

	func hasKey() -> Bool { storedKey != nil }

	func forgetIfEnrollmentChanged() -> Bool {
		state.withLock {
			guard $0.key != nil, $0.availability == .available, let saved = $0.keyEnrollment, saved != $0.enrollment else { return false }
			$0.key = nil
			return true
		}
	}

	func save(_ key: SymmetricKey) throws {
		try state.withLock {
			guard !$0.failsWrites else { throw KeychainFailure(status: errSecNotAvailable) }
			$0.key = key
			$0.keyEnrollment = $0.enrollment
		}
	}

	func read(through context: LAContext, reason: String) async throws -> StoredKeyRead {
		let asked = Asked(context: context)
		let (refusal, hook) = state.withLock {
			$0.asked.append(asked)
			$0.reasons.append(reason)
			return (Self.refusal(when: $0.availability), $0.whileLoading)
		}
		if let refusal { return refusal }
		await hook?()
		let (key, reply, availability) = state.withLock { ($0.key, $0.reply, $0.availability) }
		switch reply {
		case .key, .otherKey:
			if let refusal = Self.refusal(when: availability) { return refusal }
			guard let key else { throw Self.keyMissing }
			return .key(reply == .key ? key : SymmetricKey(data: Data(repeating: 0xEE, count: 32)))
		case .miss: return .missed
		case .cancel: return .cancelled
		case .lockout: return .lockedOut
		case .unavailable: return .unavailable
		case .failure: throw Self.readFailed
		}
	}

	private static func refusal(when availability: BiometricAvailability) -> StoredKeyRead? {
		switch availability {
		case .available: nil
		case .lockedOut: .lockedOut
		case .unavailable: .unavailable
		}
	}

	func delete() throws {
		state.withLock { $0.whileDeleting }?()
		try state.withLock {
			guard !$0.failsWrites else { throw KeychainFailure(status: errSecNotAvailable) }
			$0.key = nil
		}
	}
}
