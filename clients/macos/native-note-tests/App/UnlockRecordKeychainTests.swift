import Foundation
import Security
import Testing

@testable import NativeNoteKit

@Suite(.scratch, .serialized, .enabled(if: Keychain.holdsAccessGroup))
struct UnlockRecordKeychainTests {
	private func lookUp(_ directory: URL, _ constraint: [String: Any]) -> OSStatus {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "dev.hloth.nativenote.library",
			kSecAttrAccount as String: "unlockRecord:" + directory.standardizedFileURL.path,
			kSecUseDataProtectionKeychain as String: true,
		].merging(constraint) { $1 }
		return SecItemCopyMatching(query as CFDictionary, nil)
	}

	@Test func aBuildWithTheKeychainGroupKeepsTheRecordInTheKeychainAndNoFile() {
		let directory = temporaryDirectory()

		#expect(UnlockRecords.store(for: directory) is KeychainUnlockRecordStore)
		#expect(!FileManager.default.fileExists(atPath: AppLock.recordFile(in: directory).path))
	}

	@Test func theRecordIsKeptForThisMacOnlyNeverSyncedAndReplacedInPlace() throws {
		let directory = temporaryDirectory()
		let records = KeychainUnlockRecordStore(directory: directory)
		defer { try? records.delete() }
		#expect(try records.read() == nil)

		try records.write(.fast)
		try records.write(.sample)

		#expect(try records.read() == .sample)
		#expect(lookUp(directory, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) == errSecSuccess)
		#expect(lookUp(directory, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]) == errSecItemNotFound)
		#expect(lookUp(directory, [kSecAttrSynchronizable as String: true]) == errSecItemNotFound)
		#expect(lookUp(directory, [kSecMatchLimit as String: kSecMatchLimitAll]) == errSecSuccess)

		try records.delete()
		#expect(try records.read() == nil)
		try records.delete()
	}

	@Test func eachLibraryKeepsItsOwnRecord() throws {
		let first = KeychainUnlockRecordStore(directory: temporaryDirectory())
		let second = KeychainUnlockRecordStore(directory: temporaryDirectory())
		defer { try? first.delete() }

		try first.write(.fast)

		#expect(try first.read() == .fast)
		#expect(try second.read() == nil)
	}

	@MainActor @Test func aLibrarySetUpUnlockedAndErasedLeavesNoRecord() async throws {
		let directory = temporaryDirectory()
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: FakeKeyStore())
		model.start()
		await model.submit(password: "correct horse")
		try #require(model.phase == .unlocked)
		#expect(try KeychainUnlockRecordStore(directory: directory).read() != nil)
		#expect(!FileManager.default.fileExists(atPath: AppLock.recordFile(in: directory).path))

		await model.lock()
		await model.submit(password: "correct horse")
		#expect(model.phase == .unlocked)
		await model.lock()
		await model.eraseLibrary()

		#expect(model.phase == .needsSetup)
		#expect(try KeychainUnlockRecordStore(directory: directory).read() == nil)
	}
}
