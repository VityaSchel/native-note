import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct KeychainValueTests {
	@Test func theValueHandedToTheKeychainHoldsTheKeyAndIsWipedAfterwards() {
		let key = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0 + 1) }))

		let (handed, seen) = KeychainUnlockKeyStore.withItemValue(of: key) { ($0, Data($0 as Data)) }

		#expect(seen == key.withUnsafeBytes { Data($0) })
		#expect(CFDataGetLength(handed) == 32)
		#expect((handed as Data).allSatisfy { $0 == 0 })
	}

	@Test func theKeychainsAnswerBecomesTheKeyItHolds() throws {
		let bytes = Data((0 ..< 32).map { UInt8(255 - $0) })

		#expect(try KeychainUnlockKeyStore.key(from: bytes as NSData) == SymmetricKey(data: bytes))
	}

	@Test func aKeychainAnswerThatIsNotDataIsRejected() {
		#expect(throws: KeychainFailure(status: errSecDecode)) {
			try KeychainUnlockKeyStore.key(from: "not a key" as NSString)
		}
		#expect(throws: KeychainFailure(status: errSecDecode)) {
			try KeychainUnlockKeyStore.key(from: nil)
		}
	}
}
