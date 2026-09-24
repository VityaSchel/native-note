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

	func machineId() throws -> Data {
		KeyDerivation.derive(ikm: try agreeWithItself(), info: KeyDerivation.machineId)
	}

	private func agreeWithItself() throws -> Data {
		try key.sharedSecretFromKeyAgreement(with: key.publicKey).withUnsafeBytes { Data($0) }
	}
}
