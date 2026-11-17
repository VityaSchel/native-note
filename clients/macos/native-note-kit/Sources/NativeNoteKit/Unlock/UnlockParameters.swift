import Foundation

nonisolated struct UnlockParameters: Equatable, Sendable {
	var localSalt: Data
	var argon: Argon2.Parameters
	var enclaveKey: Data?
}

nonisolated struct UnlockRecord: Equatable, Codable, Sendable {
	static let currentVersion = 1

	var version = currentVersion
	var localSalt: Data
	var argon: Argon2.Parameters
	var enclaveKey: Data?
	var wrappedKey: Data

	init(parameters: UnlockParameters, wrappedKey: Data) {
		localSalt = parameters.localSalt
		argon = parameters.argon
		enclaveKey = parameters.enclaveKey
		self.wrappedKey = wrappedKey
	}

	var parameters: UnlockParameters {
		UnlockParameters(localSalt: localSalt, argon: argon, enclaveKey: enclaveKey)
	}
}
