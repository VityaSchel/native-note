import Foundation

nonisolated struct UnlockParameters: Equatable, Codable, Sendable {
	static let currentVersion = 1

	var version = currentVersion
	var localSalt: Data
	var argon: Argon2.Parameters
	var rounds: UInt32
	var enclaveKey: Data?
}
