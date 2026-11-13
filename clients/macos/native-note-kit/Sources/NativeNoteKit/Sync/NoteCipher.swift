import CryptoKit
import Foundation

nonisolated struct NoteCipher: Sendable {
	private let contentKey: SymmetricKey
	private let blindingKey: SymmetricKey

	init(contentKey: SymmetricKey) {
		self.contentKey = contentKey
		blindingKey = KeyDerivation.derive(ikm: contentKey, info: KeyDerivation.idBlind)
	}

	func blindedId(for id: UUID) -> Data {
		Data(HMAC<SHA256>.authenticationCode(for: id.bytes, using: blindingKey).prefix(16))
	}

	func seal(
		_ content: Content,
		v: UInt32,
		writeId: Data = Self.randomWriteId(),
		nonce: AES.GCM.Nonce = AES.GCM.Nonce()
	) throws -> Write {
		let blindedId = blindedId(for: content.id)
		let sealed = try AES.GCM.seal(
			content.encoded(),
			using: noteKey(writeId),
			nonce: nonce,
			authenticating: Self.binding(blindedId, v, writeId)
		)
		return Write(blindedId: blindedId, v: v, writeId: writeId, payload: try sealed.framed())
	}

	func open(_ write: Write) -> Content? {
		guard let box = try? AES.GCM.SealedBox(combined: write.payload),
			let plaintext = try? AES.GCM.open(box, using: noteKey(write.writeId), authenticating: Self.binding(write.blindedId, write.v, write.writeId))
		else { return nil }
		return try? Content.decode(plaintext)
	}

	static func randomWriteId() -> Data {
		Data.random(.bits128)
	}

	private func noteKey(_ writeId: Data) -> SymmetricKey {
		KeyDerivation.derive(ikm: contentKey, salt: writeId, info: KeyDerivation.note)
	}

	private static func binding(_ blindedId: Data, _ v: UInt32, _ writeId: Data) -> Data {
		var writer = WireWriter()
		writer.fixed(blindedId)
		writer.u32(v)
		writer.fixed(writeId)
		return writer.data
	}
}
