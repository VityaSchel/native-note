import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct UnlockRecordTests {
	@Test func keepsByteFieldsAsRawDataInABinaryPlist() throws {
		let encoded = try UnlockRecords.encode(.sample)

		#expect(encoded.starts(with: Data("bplist00".utf8)))

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["version"] as? Int == 1)
		#expect(plist["localSalt"] as? Data == UnlockRecord.sample.localSalt)
		#expect(plist["wrappedKey"] as? Data == UnlockRecord.sample.wrappedKey)
		#expect((plist["argon"] as? [String: Any])?["m"] as? Int == 262_144)
		#expect(try UnlockRecords.decode(encoded) == .sample)
	}

	@Test func rejectsDataThatIsNotAPropertyList() {
		#expect(throws: (any Error).self) {
			try UnlockRecords.decode(Data("not a property list".utf8))
		}
	}

	@Test func omitsTheEnclaveKeyWhenTheDeviceHasNoSecureHardware() throws {
		var withoutHardware = UnlockRecord.sample
		withoutHardware.enclaveKey = nil
		let encoded = try UnlockRecords.encode(withoutHardware)

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["enclaveKey"] == nil)
		#expect(try UnlockRecords.decode(encoded) == withoutHardware)
	}

	@Test func theWrappedKeyOpensOnlyUnderItsUnlockKey() throws {
		let key = SymmetricKey(size: .bits256)
		let record = try Unlock.makeRecord(password: "correct horse", key: key, parameters: .fast)

		#expect(record.wrappedKey.count == DatabaseKeyWrap.wrappedLength)
		#expect(try Unlock.databaseKey(password: "correct horse", record: record) == key)
		#expect(throws: Unlock.Failure.wrongPassword) { try Unlock.databaseKey(password: "Correct horse", record: record) }
		var otherSalt = record
		otherSalt.localSalt = Data(repeating: 0x81, count: 16)
		#expect(throws: Unlock.Failure.wrongPassword) { try Unlock.databaseKey(password: "correct horse", record: otherSalt) }
		var tampered = record
		tampered.wrappedKey[20] ^= 1
		#expect(throws: Unlock.Failure.wrongPassword) { try Unlock.databaseKey(password: "correct horse", record: tampered) }
		var truncated = record
		truncated.wrappedKey.removeLast()
		#expect(throws: Unlock.Failure.wrongPassword) { try Unlock.databaseKey(password: "correct horse", record: truncated) }
	}

	@Test func wrappingTheSameKeyTwiceGivesDifferentRecords() throws {
		let key = SymmetricKey(size: .bits256)

		let first = try Unlock.makeRecord(password: "correct horse", key: key, parameters: .fast)
		let second = try Unlock.makeRecord(password: "correct horse", key: key, parameters: .fast)

		#expect(first.wrappedKey != second.wrappedKey)
		#expect(try Unlock.databaseKey(password: "correct horse", record: second) == key)
	}
}
