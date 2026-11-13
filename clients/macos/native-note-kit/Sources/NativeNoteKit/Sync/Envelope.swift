import CryptoKit
import Foundation

nonisolated enum EnvelopeError: Error, Equatable {
	case tooLarge
	case unopenable
}

nonisolated struct NonceCannotBeFramed: Error, Equatable {}

nonisolated extension AES.GCM.SealedBox {
	func framed() throws(NonceCannotBeFramed) -> Data {
		guard let combined else { throw NonceCannotBeFramed() }
		return combined
	}
}

nonisolated struct EnvelopeKey: Sendable {
	static let nonceLength = 12
	private let key: SymmetricKey

	init(apiKey: SymmetricKey) {
		self.init(derived: KeyDerivation.derive(ikm: apiKey, info: KeyDerivation.envelope))
	}

	init(derived key: SymmetricKey) {
		self.key = key
	}

	static func apiKey(fromHex text: String) -> SymmetricKey? {
		SecretBytes.withUTF8(of: text.trimmingCharacters(in: .whitespacesAndNewlines)) { hex in
			guard hex.count == 64 else { return nil }
			return SecretBytes.withScratch(byteCount: 32) { bytes in
				for index in bytes.indices {
					guard let high = Hex.nibble(hex[2 * index]), let low = Hex.nibble(hex[2 * index + 1]) else { return nil }
					bytes[index] = high << 4 | low
				}
				return SymmetricKey(data: UnsafeRawBufferPointer(bytes))
			}
		}
	}

	func seal(_ inner: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
		guard let padded = Padding.pad(inner) else { throw EnvelopeError.tooLarge }
		return try AES.GCM.seal(padded, using: key, nonce: nonce).framed()
	}

	func open(_ response: Data, requestNonce: Data) throws(EnvelopeError) -> Data {
		guard let box = try? AES.GCM.SealedBox(combined: response),
			let padded = try? AES.GCM.open(box, using: key, authenticating: requestNonce),
			let inner = Padding.unpad(padded)
		else { throw .unopenable }
		return inner
	}
}
