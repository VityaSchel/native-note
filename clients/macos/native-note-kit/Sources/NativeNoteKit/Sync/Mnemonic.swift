import CryptoKit
import Foundation

/// BIP39's English word mapping and checksum for a 256-bit key; BIP39 seed derivation is never used.
nonisolated enum Mnemonic {
	static let wordCount = 24
	private static let bitsPerWord = 11
	private static let wordlistSHA256 = "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"

	/// The pinned list from spec/wordlists, or nil when the bundled file is not exactly it.
	static let wordlist: [String]? = {
		guard let url = Bundle.module.url(forResource: "english", withExtension: "txt"),
			let file = try? Data(contentsOf: url),
			SHA256.hash(data: file).map({ String(format: "%02x", $0) }).joined() == wordlistSHA256
		else { return nil }
		return String(decoding: file, as: UTF8.self).split(separator: "\n").map(String.init)
	}()

	static func words(for key: SymmetricKey) -> [String]? {
		guard let wordlist else { return nil }
		var bits = key.withUnsafeBytes { bytes in
			bytes.flatMap { byte in (0 ..< 8).map { byte >> (7 - $0) & 1 } } + checksum(bytes)
		}
		defer { bits.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		return stride(from: 0, to: bits.count, by: bitsPerWord).map { start in
			wordlist[bits[start ..< start + bitsPerWord].reduce(0) { $0 << 1 | Int($1) }]
		}
	}

	static func key(from words: [String]) -> SymmetricKey? {
		guard let wordlist, words.count == wordCount else { return nil }
		var bits: [UInt8] = []
		defer { bits.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		for word in words {
			guard let index = wordlist.firstIndex(of: word) else { return nil }
			bits += (0 ..< bitsPerWord).map { UInt8(index >> (bitsPerWord - 1 - $0) & 1) }
		}
		var entropy = stride(from: 0, to: 256, by: 8).map { start in
			bits[start ..< start + 8].reduce(UInt8(0)) { $0 << 1 | $1 }
		}
		defer { entropy.withUnsafeMutableBytes { SecretBytes.wipe($0) } }
		guard entropy.withUnsafeBytes({ checksum($0) }) == Array(bits[256...]) else { return nil }
		return SymmetricKey(data: entropy)
	}

	private static func checksum(_ entropy: UnsafeRawBufferPointer) -> [UInt8] {
		let first = SHA256.hash(data: entropy).withUnsafeBytes { $0.first ?? 0 }
		return (0 ..< 8).map { first >> (7 - $0) & 1 }
	}
}
