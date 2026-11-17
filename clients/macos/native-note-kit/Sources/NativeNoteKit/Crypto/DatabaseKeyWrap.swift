import CryptoKit
import Foundation

nonisolated enum DatabaseKeyWrap {
	static let associatedData = Data("native-note/localdb-key/v1".utf8)
	static let wrappedLength = 12 + 32 + 16

	static func wrap(_ key: SymmetricKey, under unlockKey: SymmetricKey) throws -> Data {
		let sealed = try key.withUnsafeBytes { try AES.GCM.seal($0, using: unlockKey, authenticating: associatedData) }
		guard let combined = sealed.combined else { throw CryptoKitError.incorrectParameterSize }
		return combined
	}

	static func unwrap(_ wrapped: Data, under unlockKey: SymmetricKey) -> SymmetricKey? {
		guard wrapped.count == wrappedLength,
			let box = try? AES.GCM.SealedBox(combined: wrapped),
			var opened = try? AES.GCM.open(box, using: unlockKey, authenticating: associatedData)
		else { return nil }
		defer { opened.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		guard opened.count == 32 else { return nil }
		return SymmetricKey(data: opened)
	}
}
