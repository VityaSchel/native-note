import CryptoKit
import Foundation

nonisolated enum EnvelopeError: Error, Equatable {
	case tooLarge
	case unopenable
}

/// The transport envelope of docs/PROTOCOL.md § Transport.
nonisolated struct EnvelopeKey: Sendable {
	static let nonceLength = 12
	private let key: SymmetricKey

	init(apiKey: SymmetricKey) {
		self.init(derived: KeyDerivation.derive(ikm: apiKey, info: KeyDerivation.envelope))
	}

	init(derived key: SymmetricKey) {
		self.key = key
	}

	/// The 64 lowercase hex characters of docs/PROTOCOL.md § API key, surrounding whitespace trimmed.
	static func apiKey(fromHex text: String) -> SymmetricKey? {
		let hex = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
		guard hex.count == 64 else { return nil }
		var bytes = [UInt8]()
		for pair in stride(from: 0, to: hex.count, by: 2) {
			guard let high = nibble(hex[pair]), let low = nibble(hex[pair + 1]) else { return nil }
			bytes.append(high << 4 | low)
		}
		defer { bytes.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		return SymmetricKey(data: bytes)
	}

	private static func nibble(_ digit: UInt8) -> UInt8? {
		switch digit {
		case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
		case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
		default: nil
		}
	}

	func seal(_ inner: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
		guard let padded = Padding.pad(inner),
			let combined = try AES.GCM.seal(padded, using: key, nonce: nonce).combined
		else { throw EnvelopeError.tooLarge }
		return combined
	}

	/// Opens a response sealed to the nonce of the request it answers.
	func open(_ response: Data, requestNonce: Data) throws(EnvelopeError) -> Data {
		guard let box = try? AES.GCM.SealedBox(combined: response),
			let padded = try? AES.GCM.open(box, using: key, authenticating: requestNonce),
			let inner = Padding.unpad(padded)
		else { throw .unopenable }
		return inner
	}
}
