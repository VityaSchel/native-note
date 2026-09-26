import CryptoKit
import Foundation
import SQLCipher
import SQLCipherCodec

nonisolated enum SQLiteError: Error, Equatable {
	case cannotOpen(code: Int32, message: String)
	case cannotExecute(code: Int32, message: String, sql: String)
	case keyMustBe32Bytes(count: Int)
	case wrongKey
	case newerSchema(found: Int, known: Int)
	case closed
}

nonisolated final class SQLiteConnection {
	private let handle: OpaquePointer

	init(url: URL, rawKey: SymmetricKey, create: Bool = true) throws {
		try Self.requireThirtyTwoBytes(rawKey)

		var opened: OpaquePointer?
		let code = sqlite3_open_v2(
			url.path,
			&opened,
			SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX,
			nil
		)
		guard let opened else {
			throw SQLiteError.cannotOpen(code: code, message: "sqlite3_open_v2 returned no handle")
		}
		guard code == SQLITE_OK else {
			let message = String(cString: sqlite3_errmsg(opened))
			sqlite3_close_v2(opened)
			throw SQLiteError.cannotOpen(code: code, message: message)
		}

		do {
			try Self.applyRawKey(rawKey, on: opened, with: sqlite3_key_v2, named: "sqlite3_key_v2")
			try Self.confirmKeyOpens(opened)
			try Self.execute("PRAGMA journal_mode = WAL", on: opened)
			try Self.execute("PRAGMA synchronous = FULL", on: opened)
			try Self.execute("PRAGMA fullfsync = ON", on: opened)
			try Self.execute("PRAGMA checkpoint_fullfsync = ON", on: opened)
			try Self.execute("PRAGMA foreign_keys = ON", on: opened)
		} catch {
			sqlite3_close_v2(opened)
			throw error
		}
		handle = opened
	}

	deinit { sqlite3_close_v2(handle) }

	func execute(_ sql: String) throws {
		try Self.execute(sql, on: handle)
	}

	func prepare(_ sql: String) throws -> SQLiteStatement {
		try SQLiteStatement(sql, on: handle)
	}

	func scalar(_ sql: String) throws -> String? {
		let statement = try prepare(sql)
		return try statement.step() ? statement.string(0) : nil
	}

	func transaction<T>(_ body: () throws -> T) throws -> T {
		try execute("BEGIN IMMEDIATE")
		do {
			let result = try body()
			try execute("COMMIT")
			return result
		} catch {
			try? execute("ROLLBACK")
			throw error
		}
	}

	func rekey(to newKey: SymmetricKey) throws {
		try Self.requireThirtyTwoBytes(newKey)
		try Self.applyRawKey(newKey, on: handle, with: sqlite3_rekey_v2, named: "sqlite3_rekey_v2")
	}

	private static func requireThirtyTwoBytes(_ key: SymmetricKey) throws {
		guard key.bitCount == 256 else { throw SQLiteError.keyMustBe32Bytes(count: key.bitCount / 8) }
	}

	private static func applyRawKey(
		_ rawKey: SymmetricKey,
		on handle: OpaquePointer,
		with keying: (OpaquePointer, UnsafePointer<CChar>, UnsafeRawPointer?, Int32) -> Int32,
		named call: String
	) throws {
		let code = withRawKeyLiteral(rawKey) { keying(handle, "main", $0.baseAddress, Int32($0.count)) }
		guard code == SQLITE_OK else {
			throw SQLiteError.cannotExecute(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: call)
		}
	}

	static func withRawKeyLiteral<T>(_ rawKey: SymmetricKey, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
		try rawKey.withUnsafeBytes { key in
			try SecretBytes.withScratch(byteCount: 2 * key.count + 3) { literal in
				literal[0] = UInt8(ascii: "x")
				literal[1] = UInt8(ascii: "'")
				for (index, byte) in key.enumerated() {
					literal[2 + 2 * index] = hexDigit(byte >> 4)
					literal[3 + 2 * index] = hexDigit(byte & 0x0f)
				}
				literal[literal.count - 1] = UInt8(ascii: "'")
				return try body(UnsafeRawBufferPointer(literal))
			}
		}
	}

	private static func hexDigit(_ nibble: UInt8) -> UInt8 {
		nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10
	}

	private static func confirmKeyOpens(_ handle: OpaquePointer) throws {
		let probe = "SELECT count(*) FROM sqlite_schema"
		let code = sqlite3_exec(handle, probe, nil, nil, nil)
		switch code {
		case SQLITE_OK:
			return
		case SQLITE_NOTADB:
			throw SQLiteError.wrongKey
		default:
			throw SQLiteError.cannotExecute(
				code: code,
				message: String(cString: sqlite3_errmsg(handle)),
				sql: probe
			)
		}
	}

	private static func execute(_ sql: String, on handle: OpaquePointer) throws {
		let code = sqlite3_exec(handle, sql, nil, nil, nil)
		guard code == SQLITE_OK else {
			throw SQLiteError.cannotExecute(
				code: code,
				message: String(cString: sqlite3_errmsg(handle)),
				sql: sql
			)
		}
	}
}
