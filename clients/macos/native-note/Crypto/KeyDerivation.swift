import CryptoKit
import Foundation

nonisolated enum KeyDerivation {
	static let envelope = "native-note/envelope/v1"
	static let idBlind = "native-note/id-blind/v1"
	static let note = "native-note/note/v1"
	static let localDb = "native-note/localdb/v1"
	static let chainSeed = "native-note/machine-chain/v1/seed"
	static let chainOut = "native-note/machine-chain/v1/out"

	static func chainRound(index: UInt32, attempt: UInt32) -> String {
		"native-note/machine-chain/v1/\(index)/\(attempt)"
	}

	static func derive(ikm: Data, salt: Data = Data(), info: String, length: Int = 32) -> Data {
		HKDF<SHA256>.deriveKey(
			inputKeyMaterial: SymmetricKey(data: ikm),
			salt: salt,
			info: Data(info.utf8),
			outputByteCount: length
		).withUnsafeBytes { Data($0) }
	}

	static func localDbKey(argonOut: Data, machineId: Data, localSalt: Data) -> Data {
		derive(ikm: argonOut + machineId, salt: localSalt, info: localDb)
	}
}
