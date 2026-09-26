import CryptoKit
import Foundation

nonisolated struct MachineKey {
	static var isAvailable: Bool { SecureEnclave.isAvailable }

	private let key: SecureEnclave.P256.KeyAgreement.PrivateKey

	init() throws {
		key = try SecureEnclave.P256.KeyAgreement.PrivateKey()
	}

	init(representation: Data) throws {
		key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: representation)
	}

	var representation: Data { key.dataRepresentation }

	func machineId() throws -> SymmetricKey {
		try key.sharedSecretFromKeyAgreement(with: key.publicKey).withUnsafeBytes {
			KeyDerivation.derive(ikm: SymmetricKey(data: $0), info: KeyDerivation.machineId)
		}
	}
}
