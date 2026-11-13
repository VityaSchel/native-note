import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@testable import NativeNoteKit

struct FakeKeyStoreTests {
	private static let key = SymmetricKey(data: Data(repeating: 7, count: 32))

	private func stocked() throws -> FakeKeyStore {
		let keys = FakeKeyStore()
		try keys.save(Self.key)
		return keys
	}

	private func keychainRead(refusing refusal: LAError.Code? = nil, copying status: OSStatus = errSecSuccess) async throws -> StoredKeyRead {
		let keychain = KeychainUnlockKeyStore(directory: URL(filePath: "/nowhere"))
		return try await KeychainUnlockKeyStore.read(through: LAContext()) { context in
			try keychain.copyKey(through: context) { _, result in
				result?.pointee = Self.key.withUnsafeBytes { Data($0) } as NSData
				return status
			}
		} evaluate: { _, _ in
			if let refusal { throw LAError(refusal) }
		}
	}

	@Test func aTouchReadsTheKeyFromBothStores() async throws {
		#expect(try await stocked().read(through: LAContext(), reason: "") == .key(Self.key))
		#expect(try await keychainRead() == .key(Self.key))
	}

	@Test(arguments: [
		(BiometricAvailability.unavailable, LAError.Code.biometryNotAvailable, StoredKeyRead.unavailable),
		(.lockedOut, .biometryLockout, .lockedOut),
	])
	func whileTouchIDCannotBeUsedNeitherStoreAsksForATouchOrHandsOutTheKey(availability: BiometricAvailability, refusal: LAError.Code, read: StoredKeyRead) async throws {
		let keys = try stocked()
		keys.becomes(availability)
		keys.whileLoading { Issue.record("waited for a touch while Touch ID was \(availability)") }

		#expect(try await keys.read(through: LAContext(), reason: "") == read)
		#expect(try await keychainRead(refusing: refusal) == read)
		#expect(keys.contexts.count == 1)
	}

	@Test func touchIDLockingOutDuringTheTouchHandsOutNoKey() async throws {
		let keys = try stocked()
		keys.whileLoading { keys.becomes(.lockedOut) }

		#expect(try await keys.read(through: LAContext(), reason: "") == .lockedOut)
		keys.reply(with: .miss)
		keys.becomes(.available)
		#expect(try await keys.read(through: LAContext(), reason: "") == .missed)
	}

	@Test func aMissingKeyAndAReadThatFailsAreToldApartAsInTheKeychain() async throws {
		let empty = FakeKeyStore()
		await #expect(throws: KeychainFailure(status: errSecItemNotFound)) { try await empty.read(through: LAContext(), reason: "") }
		await #expect(throws: KeychainFailure(status: errSecItemNotFound)) { try await keychainRead(copying: errSecItemNotFound) }

		let failing = try stocked()
		failing.reply(with: .failure)
		await #expect(throws: KeychainFailure(status: errSecInteractionNotAllowed)) { try await failing.read(through: LAContext(), reason: "") }
		await #expect(throws: KeychainFailure(status: errSecInteractionNotAllowed)) { try await keychainRead(copying: errSecInteractionNotAllowed) }
		#expect(FakeKeyStore.keyMissing != FakeKeyStore.readFailed)
	}

	@Test func readsAskedFromManyThreadsAtOnceAreAllRecorded() async throws {
		let keys = try stocked()

		await withTaskGroup(of: Void.self) { group in
			for _ in 0 ..< 16 {
				group.addTask { _ = try? await keys.read(through: LAContext(), reason: "at once") }
			}
		}

		#expect(keys.reasons == Array(repeating: "at once", count: 16))
		#expect(Set(keys.contexts.map(ObjectIdentifier.init)).count == 16)
	}
}
