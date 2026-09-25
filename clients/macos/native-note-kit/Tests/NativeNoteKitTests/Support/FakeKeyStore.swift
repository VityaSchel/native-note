import Foundation
import Synchronization

@testable import NativeNoteKit

final class FakeKeyStore: UnlockKeyStore {
	enum Reply: Sendable {
		case key
		case cancel
		case failure
	}

	private struct State {
		var key: Data?
		var reply = Reply.key
		var failsWrites = false
		let available: Bool
	}

	private let state: Mutex<State>

	init(available: Bool = true) {
		state = Mutex(State(available: available))
	}

	var storedKey: Data? { state.withLock { $0.key } }

	func reply(with reply: Reply) {
		state.withLock { $0.reply = reply }
	}

	func failWrites() {
		state.withLock { $0.failsWrites = true }
	}

	func plant(_ key: Data) {
		state.withLock { $0.key = key }
	}

	var isAvailable: Bool { state.withLock { $0.available } }

	func hasKey() -> Bool { storedKey != nil }

	func save(_ key: Data) throws {
		try state.withLock {
			guard !$0.failsWrites else { throw KeychainFailure(status: errSecNotAvailable) }
			$0.key = key
		}
	}

	func load(reason: String) async throws -> Data? {
		let (key, reply) = state.withLock { ($0.key, $0.reply) }
		switch reply {
		case .key: return key
		case .cancel: return nil
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
