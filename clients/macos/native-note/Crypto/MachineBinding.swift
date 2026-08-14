import CryptoKit
import Foundation

nonisolated enum MachineBinding {
	static func machineId(key: MachineKey) throws -> Data {
		KeyDerivation.derive(ikm: try key.agreeWithItself(), info: KeyDerivation.machineId)
	}
}

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

	fileprivate func agreeWithItself() throws -> Data {
		try key.sharedSecretFromKeyAgreement(with: key.publicKey).withUnsafeBytes { Data($0) }
	}
}
