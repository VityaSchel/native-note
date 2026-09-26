import CryptoKit
import Foundation

nonisolated enum KeyDerivation {
	static let envelope = "native-note/envelope/v1"
	static let idBlind = "native-note/id-blind/v1"
	static let note = "native-note/note/v1"
	static let localDb = "native-note/localdb/v1"
	static let machineId = "native-note/machine-id/v1"

	static func derive(ikm: SymmetricKey, salt: Data = Data(), info: String, length: Int = 32) -> SymmetricKey {
		HKDF<SHA256>.deriveKey(
			inputKeyMaterial: ikm,
			salt: salt,
			info: Data(info.utf8),
			outputByteCount: length
		)
	}

	static func localDbKey(argonOut: SymmetricKey, machineId: SymmetricKey?, localSalt: Data) -> SymmetricKey {
		let argonCount = argonOut.bitCount / 8
		return SecretBytes.withScratch(byteCount: argonCount + (machineId?.bitCount ?? 0) / 8) { ikm in
			argonOut.withUnsafeBytes { ikm.copyMemory(from: $0) }
			machineId?.withUnsafeBytes { UnsafeMutableRawBufferPointer(rebasing: ikm[argonCount...]).copyMemory(from: $0) }
			return derive(ikm: SymmetricKey(data: UnsafeRawBufferPointer(ikm)), salt: localSalt, info: localDb)
		}
	}
}
