import CryptoKit
import Foundation

/// `contentKeyEncrypted` of docs/PROTOCOL.md § Recovery key: the Content key sealed under the Recovery key.
nonisolated enum RecoveryBlob {
	static func seal(_ contentKey: SymmetricKey, under recoveryKey: SymmetricKey, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
		let sealed = try contentKey.withUnsafeBytes { try AES.GCM.seal($0, using: recoveryKey, nonce: nonce) }
		guard let blob = sealed.combined else { throw EnvelopeError.unopenable }
		return blob
	}

	/// The Content key, if the blob opens under the Recovery key to exactly 32 bytes.
	static func open(_ blob: Data, under recoveryKey: SymmetricKey) -> SymmetricKey? {
		guard let box = try? AES.GCM.SealedBox(combined: blob),
			var plaintext = try? AES.GCM.open(box, using: recoveryKey)
		else { return nil }
		defer { plaintext.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		return plaintext.count == 32 ? SymmetricKey(data: plaintext) : nil
	}
}
