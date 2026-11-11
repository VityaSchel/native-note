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

	/// Bits are read in place rather than collected, so no array of key bits outlives the call.
	static func words(for key: SymmetricKey) -> [String]? {
		guard let wordlist else { return nil }
		return key.withUnsafeBytes { entropy in
			let checksum = checksum(entropy)
			func bit(_ index: Int) -> Int {
				Int((index < 256 ? entropy[index / 8] << (index % 8) : checksum << (index - 256)) >> 7)
			}
			return (0 ..< wordCount).map { word in
				wordlist[(0 ..< bitsPerWord).reduce(0) { $0 << 1 | bit(word * bitsPerWord + $1) }]
			}
		}
	}

	static func key(from words: [String]) -> SymmetricKey? {
		guard let wordlist, words.count == wordCount else { return nil }
		return SecretBytes.withScratch(byteCount: wordCount * MemoryLayout<Int>.stride) { scratch in
			let indices = scratch.bindMemory(to: Int.self)
			for (position, word) in words.enumerated() {
				guard let index = wordlist.firstIndex(of: word) else { return nil }
				indices[position] = index
			}
			func bit(_ index: Int) -> UInt8 {
				UInt8(indices[index / bitsPerWord] >> (bitsPerWord - 1 - index % bitsPerWord) & 1)
			}
			return SecretBytes.withScratch(byteCount: 32) { entropy in
				for byte in entropy.indices {
					entropy[byte] = (0 ..< 8).reduce(0) { $0 << 1 | bit(byte * 8 + $1) }
				}
				let expected = (0 ..< 8).reduce(UInt8(0)) { $0 << 1 | bit(256 + $1) }
				return checksum(UnsafeRawBufferPointer(entropy)) == expected ? SymmetricKey(data: UnsafeRawBufferPointer(entropy)) : nil
			}
		}
	}

	private static func checksum(_ entropy: UnsafeRawBufferPointer) -> UInt8 {
		SHA256.hash(data: entropy).withUnsafeBytes { $0.first ?? 0 }
	}
}
