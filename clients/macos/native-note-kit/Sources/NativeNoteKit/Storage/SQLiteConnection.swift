import Foundation
import SQLCipher

nonisolated enum SQLiteError: Error, Equatable {
	case cannotOpen(code: Int32, message: String)
	case cannotExecute(code: Int32, message: String, sql: String)
	case keyMustBe32Bytes(count: Int)
	case wrongKey
	case checkpointBlocked
	case newerSchema(found: Int, known: Int)
	case closed
}

nonisolated final class SQLiteConnection {
	private let handle: OpaquePointer

	init(url: URL, rawKey: Data) throws {
		guard rawKey.count == 32 else { throw SQLiteError.keyMustBe32Bytes(count: rawKey.count) }

		var opened: OpaquePointer?
		let code = sqlite3_open_v2(
			url.path,
			&opened,
			SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
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
			try Self.applyRawKey("key", rawKey, on: opened)
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

	func rekey(to newKey: Data) throws {
		guard newKey.count == 32 else { throw SQLiteError.keyMustBe32Bytes(count: newKey.count) }
		try Self.applyRawKey("rekey", newKey, on: handle)
	}

	func checkpoint() throws {
		let statement = try prepare("PRAGMA wal_checkpoint(TRUNCATE)")
		guard try statement.step(), statement.int(0) == 0 else { throw SQLiteError.checkpointBlocked }
	}

	private static func applyRawKey(_ pragma: String, _ rawKey: Data, on handle: OpaquePointer) throws {
		let hex = rawKey.map { String(format: "%02x", $0) }.joined()
		let code = sqlite3_exec(handle, "PRAGMA \(pragma) = \"x'\(hex)'\"", nil, nil, nil)
		guard code == SQLITE_OK else {
			throw SQLiteError.cannotExecute(
				code: code,
				message: String(cString: sqlite3_errmsg(handle)),
				sql: "PRAGMA \(pragma)"
			)
		}
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
