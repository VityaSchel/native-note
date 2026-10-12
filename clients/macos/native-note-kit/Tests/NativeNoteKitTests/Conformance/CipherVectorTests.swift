import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct CipherVectorTests {
	@Test func blindedIdsMatchAndOneBitApartDiffer() throws {
		let vectors = try Vectors.load(.blinding)
		let contentKey = try key(try #require(vectors.first { $0.name == "blindingKey" }), "contentKey")
		let blinding = try #require(vectors.first { $0.name == "blindingKey" })
		#expect(KeyDerivation.derive(ikm: contentKey, info: KeyDerivation.idBlind) == (try key(blinding, "blindingKey")))
		let ids = try vectors.filter { $0.bytes("blindedId") != nil }.map { vector in
			let id = try #require(vector.string("uuid").flatMap(UUID.init(uuidString:)))
			#expect(id.bytes == (try vector.require("uuidBytes")))
			let blindedId = NoteCipher(contentKey: contentKey).blindedId(for: id)
			#expect(blindedId == (try vector.require("blindedId")), "\(vector.name)")
			return blindedId
		}
		#expect(Set(ids).count == 2)
	}

	@Test func notePayloadsSealExactlyOpenAndRefuseAnotherVersion() throws {
		for vector in try Vectors.load(.note) {
			let cipher = NoteCipher(contentKey: try key(vector, "contentKey"))
			let expected = try content(from: try #require(vector.object("content")))
			let v = UInt32(try #require(vector.int("v")))
			let write = try cipher.seal(expected, v: v, writeId: try vector.require("writeId"), nonce: try nonce(vector))
			#expect(write.blindedId == (try vector.require("blindedId")), "\(vector.name)")
			#expect(write.payload == (try vector.require("payload")), "\(vector.name)")
			#expect(expected.encoded() == (try vector.require("plaintext")), "\(vector.name)")
			#expect(cipher.open(write) == expected, "\(vector.name)")
			let bumped = Write(blindedId: write.blindedId, v: v + 1, writeId: write.writeId, payload: write.payload)
			#expect(cipher.open(bumped) == nil, "\(vector.name)")
		}
	}

	/// Opening a request is the server's, replayed by the core.
	private static let serverOnly: Set = ["rejectResponseOpenedAsRequest"]

	@Test func envelopesSealRequestsExactlyAndOpenOnlyTheirOwnResponses() throws {
		for vector in try Vectors.load(.envelope) where !Self.serverOnly.contains(vector.name) {
			let envelope = EnvelopeKey(derived: try key(vector, "envelopeKey"))
			if let apiKey = vector.bytes("apiKey") {
				let derived = EnvelopeKey(apiKey: SymmetricKey(data: apiKey))
				#expect(try derived.seal(try vector.require("inner"), nonce: try nonce(vector)) == (try vector.require("frame")))
			}
			let frame = try vector.require("frame")
			switch vector.name {
			case "request":
				#expect(try envelope.seal(try vector.require("inner"), nonce: try nonce(vector)) == frame)
			case "response":
				#expect(try envelope.open(frame, requestNonce: try vector.require("requestNonce")) == (try vector.require("inner")))
			case let name where name.hasPrefix("errorFor"):
				let reply = try envelope.open(try vector.require("response"), requestNonce: frame.prefix(EnvelopeKey.nonceLength))
				#expect(reply == (try vector.require("responseInner")))
				#expect(try Response.decode(reply) == .error)
			default:
				#expect(vector.bool("opens") == false)
				let requestNonce = vector.bytes("requestNonce") ?? frame.prefix(EnvelopeKey.nonceLength)
				#expect(throws: EnvelopeError.unopenable, "\(vector.name)") {
					try envelope.open(frame, requestNonce: requestNonce)
				}
			}
		}
	}

	@Test func anAPIKeyIsExactly64LowercaseHexCharacters() throws {
		let hex = String(repeating: "0a", count: 32)
		#expect(EnvelopeKey.apiKey(fromHex: "  \(hex)\n") == SymmetricKey(data: Data(repeating: 0x0a, count: 32)))
		for bad in [hex.uppercased(), String(hex.dropLast()), hex + "0", String(hex.dropLast()) + "g", ""] {
			#expect(EnvelopeKey.apiKey(fromHex: bad) == nil, "\(bad)")
		}
	}

	@Test func recoveryBlobsSealExactlyAndOpenOnlyToAThirtyTwoByteKeyUnderTheirOwnRecoveryKey() throws {
		for vector in try Vectors.load(.recovery) where vector.bytes("blob") != nil {
			let blob = try vector.require("blob")
			let opened = RecoveryBlob.open(blob, under: try key(vector, "recoveryKey"))
			#expect((opened != nil) == vector.bool("opens"), "\(vector.name)")
			guard vector.name == "blob" else { continue }
			let contentKey = try key(vector, "contentKey")
			#expect(opened == contentKey)
			#expect(try RecoveryBlob.seal(contentKey, under: try key(vector, "recoveryKey"), nonce: try nonce(vector)) == blob)
			let words = try #require(vector.string("mnemonic")).split(separator: " ").map(String.init)
			#expect(Mnemonic.words(for: try key(vector, "recoveryKey")) == words)
		}
	}

	@Test func mnemonicsUseThePinnedListAndRejectBadChecksumsCountsAndWords() throws {
		for vector in try Vectors.load(.mnemonic) {
			if vector.name == "wordlist" {
				let wordlist = try #require(Mnemonic.wordlist)
				#expect(wordlist.count == vector.int("count"))
				#expect(wordlist.first == vector.string("first"))
				#expect(wordlist.last == vector.string("last"))
				continue
			}
			let words = try #require(vector.string("mnemonic")).split(separator: " ").map(String.init)
			let decoded = Mnemonic.key(from: words)
			#expect((decoded != nil) == vector.bool("decodes"), "\(vector.name)")
			if let entropy = vector.bytes("entropy") {
				#expect(decoded == SymmetricKey(data: entropy))
				#expect(Mnemonic.words(for: SymmetricKey(data: entropy)) == words)
			}
		}
	}
}
