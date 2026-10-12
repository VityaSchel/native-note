import CryptoKit
import Foundation

/// Puts and gets of the recovery blob under the pin rule, per clients/DESIGN.md § Recovery flow.
nonisolated struct RecoveryFlow: Sendable {
	enum Failure: Error, Equatable {
		/// The server already holds a blob, so this library joins it rather than setting up.
		case serverHasLibrary
		/// Another device put a blob this Recovery key does not open.
		case rotatedElsewhere
		case serverBehind
	}

	private static let attempts = 3
	let connection: SyncConnection

	func storedVersion() async throws -> UInt32 {
		try await get().v
	}

	/// Puts the Content key under the Recovery key at `pin + 1`, sending it again unchanged after a lost response, and returns the new pin.
	func put(_ contentKey: SymmetricKey, under recoveryKey: SymmetricKey, pin: UInt32) async throws -> UInt32 {
		guard pin < .max else { throw Failure.rotatedElsewhere }
		let request = Request.put(v: pin + 1, blob: try RecoveryBlob.seal(contentKey, under: recoveryKey))
		switch try await sendAgainIfLost(request) {
		case let .put(.accepted, v) where v == pin + 1:
			return v
		case let .put(.conflict, v) where v >= pin:
			let stored = try await get()
			guard RecoveryBlob.open(stored.blob, under: recoveryKey) != nil else { throw Failure.rotatedElsewhere }
			return stored.v
		case .put(.conflict, _):
			throw Failure.serverBehind
		default:
			throw SyncError.protocolViolation
		}
	}

	/// The stored `v`, once the stored blob opens under `recoveryKey` to `contentKey`.
	func pin(opening contentKey: SymmetricKey, under recoveryKey: SymmetricKey) async throws -> UInt32? {
		let stored = try await get()
		return RecoveryBlob.open(stored.blob, under: recoveryKey) == contentKey ? stored.v : nil
	}

	private func get() async throws -> (v: UInt32, blob: Data) {
		guard case let .get(v, blob) = try await sendAgainIfLost(.get), (v == 0) == blob.isEmpty else {
			throw SyncError.protocolViolation
		}
		return (v, blob)
	}

	private func sendAgainIfLost(_ request: Request) async throws -> Response {
		var attempt = 1
		while true {
			do {
				return try await connection.send(request)
			} catch is URLError where attempt < Self.attempts {
				attempt += 1
			}
		}
	}
}
