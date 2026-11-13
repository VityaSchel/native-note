import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct SealFailureTests {
	@Test func sealingUnderANonceTheFrameCannotCarryIsItsOwnError() throws {
		let nonce = try AES.GCM.Nonce(data: Data(count: 16))
		let key = SymmetricKey(size: .bits256)

		#expect(throws: NonceCannotBeFramed.self) {
			try NoteCipher(contentKey: key).seal(.tombstone(id: UUID(), deletedAt: 0), v: 1, nonce: nonce)
		}
		#expect(throws: NonceCannotBeFramed.self) { try RecoveryBlob.seal(key, under: key, nonce: nonce) }
		#expect(throws: NonceCannotBeFramed.self) { try EnvelopeKey(apiKey: key).seal(Data(), nonce: nonce) }
	}
}
