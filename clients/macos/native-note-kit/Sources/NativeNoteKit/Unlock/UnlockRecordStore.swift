import Foundation
import Security

nonisolated protocol UnlockRecordStore: Sendable {
	func read() throws -> UnlockRecord?
	func write(_ record: UnlockRecord) throws
	func delete() throws
}

nonisolated enum UnlockRecords {
	static func store(for directory: URL) -> any UnlockRecordStore {
		Keychain.holdsAccessGroup ? KeychainUnlockRecordStore(directory: directory) : FileUnlockRecordStore(directory: directory)
	}

	static func encode(_ record: UnlockRecord) throws -> Data {
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		return try encoder.encode(record)
	}

	static func decode(_ data: Data) throws -> UnlockRecord {
		let record = try PropertyListDecoder().decode(UnlockRecord.self, from: data)
		guard record.version == UnlockRecord.currentVersion else {
			throw AppLock.Unreadable.unsupportedVersion(record.version)
		}
		return record
	}
}

nonisolated struct FileUnlockRecordStore: UnlockRecordStore {
	let file: URL

	init(directory: URL) {
		file = AppLock.recordFile(in: directory)
	}

	func read() throws -> UnlockRecord? {
		guard FileManager.default.fileExists(atPath: file.path) else { return nil }
		return try UnlockRecords.decode(Data(contentsOf: file))
	}

	func write(_ record: UnlockRecord) throws {
		try AppLock.durablyReplace(file, with: UnlockRecords.encode(record))
	}

	func delete() throws {
		guard FileManager.default.fileExists(atPath: file.path) else { return }
		try FileManager.default.removeItem(at: file)
	}
}

nonisolated struct KeychainUnlockRecordStore: UnlockRecordStore {
	private let account: String

	init(directory: URL) {
		account = "unlockRecord:" + directory.standardizedFileURL.path
	}

	func read() throws -> UnlockRecord? {
		var query = baseQuery
		query[kSecReturnData as String] = true
		var result: AnyObject?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		switch status {
		case errSecSuccess:
			guard let data = result as? Data else { throw KeychainFailure(status: errSecDecode) }
			return try UnlockRecords.decode(data)
		case errSecItemNotFound:
			return nil
		default:
			throw KeychainFailure(status: status)
		}
	}

	func write(_ record: UnlockRecord) throws {
		let data = try UnlockRecords.encode(record)
		let updated = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		guard updated == errSecItemNotFound else {
			guard updated == errSecSuccess else { throw KeychainFailure(status: updated) }
			return
		}
		var item = baseQuery
		item[kSecValueData as String] = data
		item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
		let added = SecItemAdd(item as CFDictionary, nil)
		guard added == errSecSuccess else { throw KeychainFailure(status: added) }
	}

	func delete() throws {
		let status = SecItemDelete(baseQuery as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
	}

	private var baseQuery: [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "dev.hloth.nativenote.library",
			kSecAttrAccount as String: account,
			kSecAttrSynchronizable as String: false,
			kSecUseDataProtectionKeychain as String: true,
		]
	}
}
