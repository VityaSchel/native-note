import Foundation
import LocalAuthentication
import Security

nonisolated public protocol UnlockKeyStore: Sendable {
	var isAvailable: Bool { get }
	func hasKey() -> Bool
	func save(_ key: Data) throws
	func load(reason: String) async throws -> Data?
	func delete() throws
}

nonisolated struct KeychainFailure: Error, Equatable {
	let status: OSStatus

	var message: String {
		SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
	}
}

nonisolated struct KeychainUnlockKeyStore: UnlockKeyStore {
	static let accessGroupEntitlement = "keychain-access-groups"

	private let account: String

	init(directory: URL) {
		account = "localDbKey:" + directory.standardizedFileURL.path
	}

	var isAvailable: Bool {
		guard let task = SecTaskCreateFromSelf(nil) else { return false }
		return SecTaskCopyValueForEntitlement(task, Self.accessGroupEntitlement as CFString, nil) != nil
			&& LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
	}

	func hasKey() -> Bool {
		let context = LAContext()
		context.interactionNotAllowed = true
		var query = baseQuery
		query[kSecReturnAttributes as String] = true
		query[kSecUseAuthenticationContext as String] = context
		let status = SecItemCopyMatching(query as CFDictionary, nil)
		return status == errSecSuccess || status == errSecInteractionNotAllowed
	}

	func save(_ key: Data) throws {
		var error: Unmanaged<CFError>?
		guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
			throw error.map { $0.takeRetainedValue() as Error } ?? KeychainFailure(status: errSecParam)
		}
		try delete()
		var item = baseQuery
		item[kSecValueData as String] = key
		item[kSecAttrAccessControl as String] = access
		let status = SecItemAdd(item as CFDictionary, nil)
		guard status == errSecSuccess else { throw KeychainFailure(status: status) }
	}

	func load(reason: String) async throws -> Data? {
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(with: Result { try read(reason: reason, interactive: true) })
			}
		}
	}

	func read(reason: String, interactive: Bool) throws -> Data? {
		let context = LAContext()
		context.localizedReason = reason
		context.interactionNotAllowed = !interactive
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecUseAuthenticationContext as String] = context
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let key = result as? Data else { throw KeychainFailure(status: errSecDecode) }
			return key
		case errSecUserCanceled, errSecAuthFailed:
			return nil
		default:
			throw KeychainFailure(status: status)
		}
	}

	func delete() throws {
		let status = SecItemDelete(baseQuery as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
	}

	private var baseQuery: [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "dev.hloth.nativenote.unlock",
			kSecAttrAccount as String: account,
			kSecUseDataProtectionKeychain as String: true,
		]
	}
}
