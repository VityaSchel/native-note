import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated public protocol UnlockKeyStore: Sendable {
	var isAvailable: Bool { get }
	func hasKey() -> Bool
	func save(_ key: SymmetricKey) throws
	func load(reason: String) async throws -> SymmetricKey?
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

	func save(_ key: SymmetricKey) throws {
		var error: Unmanaged<CFError>?
		guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
			throw error.map { $0.takeRetainedValue() as Error } ?? KeychainFailure(status: errSecParam)
		}
		try delete()
		try Self.withItemValue(of: key) { value in
			var item = baseQuery
			item[kSecValueData as String] = value
			item[kSecAttrAccessControl as String] = access
			let status = SecItemAdd(item as CFDictionary, nil)
			guard status == errSecSuccess else { throw KeychainFailure(status: status) }
		}
	}

	static func withItemValue<T>(of key: SymmetricKey, _ body: (CFMutableData) throws -> T) rethrows -> T {
		let value: CFMutableData = CFDataCreateMutable(nil, key.bitCount / 8)
		key.withUnsafeBytes { CFDataAppendBytes(value, $0.baseAddress?.assumingMemoryBound(to: UInt8.self), $0.count) }
		defer { SecretBytes.wipe(UnsafeMutableRawBufferPointer(start: CFDataGetMutableBytePtr(value), count: CFDataGetLength(value))) }
		return try body(value)
	}

	static func key(from item: AnyObject?) throws -> SymmetricKey {
		guard let value = item as? NSData else { throw KeychainFailure(status: errSecDecode) }
		return SymmetricKey(data: UnsafeRawBufferPointer(start: value.bytes, count: value.length))
	}

	func load(reason: String) async throws -> SymmetricKey? {
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				continuation.resume(with: Result { try read(reason: reason, interactive: true) })
			}
		}
	}

	func read(reason: String, interactive: Bool) throws -> SymmetricKey? {
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
			return try Self.key(from: result)
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
