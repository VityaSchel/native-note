import CryptoKit
import LocalAuthentication
import NativeNoteKit

nonisolated struct AbsentKeyStore: UnlockKeyStore {
	var availability: BiometricAvailability { .unavailable }

	func hasKey() -> Bool { false }

	func save(_ key: SymmetricKey) throws {}

	func read(through context: LAContext, reason: String) async throws -> StoredKeyRead { .unavailable }

	func delete() throws {}
}
