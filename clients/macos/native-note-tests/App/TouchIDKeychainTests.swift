import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing

@testable import NativeNote
@testable import NativeNoteKit

private let touchIDReady = KeychainUnlockKeyStore(directory: URL(fileURLWithPath: "/dev/null")).isAvailable

private final class TouchAcceptedKeychain: UnlockKeyStore {
	private let keychain: KeychainUnlockKeyStore
	private let saved = Mutex<Data?>(nil)

	init(directory: URL) {
		keychain = KeychainUnlockKeyStore(directory: directory)
	}

	var isAvailable: Bool { keychain.isAvailable }

	func hasKey() -> Bool { keychain.hasKey() }

	func save(_ key: Data) throws {
		try keychain.save(key)
		saved.withLock { $0 = key }
	}

	func load(reason: String) async throws -> Data? {
		saved.withLock { $0 }
	}

	func delete() throws {
		try keychain.delete()
	}
}

@MainActor @Suite(.serialized, .enabled(if: touchIDReady))
struct TouchIDKeychainTests {
	private func lookUp(_ directory: URL, _ constraint: [String: Any]) -> OSStatus {
		let context = LAContext()
		context.interactionNotAllowed = true
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "dev.hloth.nativenote.unlock",
			kSecAttrAccount as String: "localDbKey:" + directory.standardizedFileURL.path,
			kSecUseDataProtectionKeychain as String: true,
			kSecUseAuthenticationContext as String: context,
		].merging(constraint) { $1 }
		return SecItemCopyMatching(query as CFDictionary, nil)
	}

	@Test func theKeyIsProtectedForThisMacOnlyAndNeverSynced() throws {
		let directory = temporaryDirectory()
		let keys = KeychainUnlockKeyStore(directory: directory)
		defer { try? keys.delete() }

		try keys.save(Data(repeating: 7, count: 32))

		#expect(lookUp(directory, [kSecAttrAccessible as String: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]) == errSecInteractionNotAllowed)
		#expect(lookUp(directory, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]) == errSecItemNotFound)
		#expect(lookUp(directory, [kSecAttrSynchronizable as String: true]) == errSecItemNotFound)
	}

	@Test func theUnlockKeyIsKeptBehindTouchID() throws {
		let directory = temporaryDirectory()
		let keys = KeychainUnlockKeyStore(directory: directory)
		defer { try? keys.delete() }

		try keys.save(Data((0 ..< 32).map { UInt8($0) }))

		#expect(keys.hasKey())
		#expect(throws: KeychainFailure(status: errSecInteractionNotAllowed)) {
			try keys.read(reason: "check the key needs Touch ID", interactive: false)
		}

		try keys.delete()
		#expect(!keys.hasKey())
	}

	@Test func savingAgainReplacesTheKey() throws {
		let keys = KeychainUnlockKeyStore(directory: temporaryDirectory())
		defer { try? keys.delete() }

		try keys.save(Data(repeating: 1, count: 32))
		try keys.save(Data(repeating: 2, count: 32))

		#expect(keys.hasKey())
	}

	@Test func eachLibraryKeepsItsOwnKey() throws {
		let first = KeychainUnlockKeyStore(directory: temporaryDirectory())
		let second = KeychainUnlockKeyStore(directory: temporaryDirectory())
		defer { try? first.delete() }

		try first.save(Data(repeating: 1, count: 32))

		#expect(first.hasKey())
		#expect(!second.hasKey())
	}

	@Test func aLibraryTurnsTouchIDOnAndOffUpToThePrompt() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: TouchAcceptedKeychain(directory: directory))
		defer { try? KeychainUnlockKeyStore(directory: directory).delete() }
		model.start()
		await model.submit(password: "correct horse")
		try #require(model.phase == .unlocked)

		#expect(await model.enableBiometricUnlock())
		await model.lock()
		#expect(model.canUnlockWithBiometrics)
		#expect(KeychainUnlockKeyStore(directory: directory).hasKey())

		model.disableBiometricUnlock()
		#expect(!model.canUnlockWithBiometrics)
		#expect(!KeychainUnlockKeyStore(directory: directory).hasKey())
	}

	@Test func erasingTheLibraryRemovesItsTouchIDKey() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { try? KeychainUnlockKeyStore(directory: directory).delete() }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: TouchAcceptedKeychain(directory: directory))
		model.start()
		await model.submit(password: "correct horse")
		#expect(await model.enableBiometricUnlock())
		await model.lock()

		await model.eraseLibrary()

		#expect(model.phase == .needsSetup)
		#expect(!KeychainUnlockKeyStore(directory: directory).hasKey())
	}
}
