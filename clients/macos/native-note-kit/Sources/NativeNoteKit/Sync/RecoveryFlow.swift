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
		/// A join found no blob to open.
		case noLibrary
		/// A put may have landed, but neither its answer nor the stored blob could be read.
		case outcomeUnknown
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
		var mayHaveLanded = false
		let response: Response
		do {
			response = try await sendAgainIfLost(request) { mayHaveLanded = mayHaveLanded || !Self.neverSent.contains($0.code) }
		} catch let error as URLError where !mayHaveLanded {
			throw error
		} catch {
			return try await landed(contentKey, under: recoveryKey, pin: pin, failure: error)
		}
		switch response {
		case let .put(.accepted, v) where v == pin + 1:
			return v
		case let .put(.conflict, v) where v >= pin:
			let stored: (v: UInt32, blob: Data)
			do {
				stored = try await get()
			} catch {
				throw Failure.outcomeUnknown
			}
			guard RecoveryBlob.open(stored.blob, under: recoveryKey) != nil else { throw Failure.rotatedElsewhere }
			return stored.v
		case .put(.conflict, _):
			throw Failure.serverBehind
		default:
			throw SyncError.protocolViolation
		}
	}

	/// After a put whose answer was lost or replaced, as by a proxy that forwarded it and then failed: the stored blob shows whether it landed.
	private func landed(_ contentKey: SymmetricKey, under recoveryKey: SymmetricKey, pin: UInt32, failure: Error) async throws -> UInt32 {
		let stored: (v: UInt32, blob: Data)
		do {
			stored = try await get()
		} catch {
			throw Failure.outcomeUnknown
		}
		if stored.v > pin, RecoveryBlob.open(stored.blob, under: recoveryKey) == contentKey { return stored.v }
		if stored.v > pin { throw Failure.rotatedElsewhere }
		if stored.v < pin { throw Failure.serverBehind }
		throw failure
	}

	private static let neverSent: Set<URLError.Code> = [.badURL, .unsupportedURL, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]

	/// The stored `v`, once the stored blob opens under `recoveryKey` to `contentKey`.
	func pin(opening contentKey: SymmetricKey, under recoveryKey: SymmetricKey) async throws -> UInt32? {
		let stored = try await get()
		return RecoveryBlob.open(stored.blob, under: recoveryKey) == contentKey ? stored.v : nil
	}

	/// The Content key the stored blob holds under `recoveryKey`, with the stored `v` to pin; nil when it does not open.
	func join(under recoveryKey: SymmetricKey) async throws -> (contentKey: SymmetricKey, pin: UInt32)? {
		let stored = try await get()
		guard stored.v > 0 else { throw Failure.noLibrary }
		return RecoveryBlob.open(stored.blob, under: recoveryKey).map { ($0, stored.v) }
	}

	private func get() async throws -> (v: UInt32, blob: Data) {
		guard case let .get(v, blob) = try await sendAgainIfLost(.get), (v == 0) == blob.isEmpty else {
			throw SyncError.protocolViolation
		}
		return (v, blob)
	}

	private func sendAgainIfLost(_ request: Request, noting lost: (URLError) -> Void = { _ in }) async throws -> Response {
		var attempt = 1
		while true {
			do {
				return try await connection.send(request)
			} catch let error as URLError {
				lost(error)
				guard attempt < Self.attempts else { throw error }
				attempt += 1
			}
		}
	}
}
