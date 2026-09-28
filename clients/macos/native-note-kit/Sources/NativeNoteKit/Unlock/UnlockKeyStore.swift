import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated public enum BiometricAvailability: Sendable, Equatable {
	case available
	case lockedOut
	case unavailable
}

nonisolated public enum StoredKeyRead: Sendable, Equatable {
	case key(SymmetricKey)
	case missed
	case lockedOut
	case cancelled
	case unavailable
}

nonisolated public protocol UnlockKeyStore: Sendable {
	var availability: BiometricAvailability { get }
	func hasKey() -> Bool
	func save(_ key: SymmetricKey) throws
	func read(through context: LAContext, reason: String) async throws -> StoredKeyRead
	func delete() throws
}

extension UnlockKeyStore {
	nonisolated public var isAvailable: Bool {
		availability == .available
	}
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

	var availability: BiometricAvailability {
		guard let task = SecTaskCreateFromSelf(nil), SecTaskCopyValueForEntitlement(task, Self.accessGroupEntitlement as CFString, nil) != nil else {
			return .unavailable
		}
		var error: NSError?
		let canEvaluate = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
		return Self.availability(canEvaluate: canEvaluate, error: error)
	}

	static func availability(canEvaluate: Bool, error: Error?) -> BiometricAvailability {
		if canEvaluate { return .available }
		return (error as? LAError)?.code == .biometryLockout ? .lockedOut : .unavailable
	}

	static func accessControl() throws -> SecAccessControl {
		var error: Unmanaged<CFError>?
		guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
			throw error.map { $0.takeRetainedValue() as Error } ?? KeychainFailure(status: errSecParam)
		}
		return access
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
		let access = try Self.accessControl()
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

	func read(through context: LAContext, reason: String) async throws -> StoredKeyRead {
		try await Self.read(through: context, copy: { try copyKey(through: $0) }) {
			_ = try await $0.evaluateAccessControl($1, operation: .useItem, localizedReason: reason)
		}
	}

	static func read(
		through context: LAContext,
		copy: (LAContext) throws -> StoredKeyRead,
		evaluate: (LAContext, SecAccessControl) async throws -> Void
	) async throws -> StoredKeyRead {
		defer { context.invalidate() }
		do {
			try await evaluate(context, try accessControl())
		} catch {
			return try outcome(ofEvaluation: error)
		}
		return try copy(context)
	}

	static func outcome(ofEvaluation error: Error) throws -> StoredKeyRead {
		guard let refusal = error as? LAError else { throw error }
		switch refusal.code {
		case .authenticationFailed:
			return .missed
		case .biometryLockout:
			return .lockedOut
		case .biometryNotAvailable, .biometryNotEnrolled, .biometryNotPaired, .biometryDisconnected, .passcodeNotSet:
			return .unavailable
		default:
			return .cancelled
		}
	}

	func copyKey(
		through context: LAContext,
		matching copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
	) throws -> StoredKeyRead {
		context.interactionNotAllowed = true
		var query = baseQuery
		query[kSecReturnData as String] = true
		query[kSecUseAuthenticationContext as String] = context
		var result: AnyObject?
		let status = copyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			return .key(try Self.key(from: result))
		case errSecUserCanceled, errSecAuthFailed:
			return .cancelled
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
