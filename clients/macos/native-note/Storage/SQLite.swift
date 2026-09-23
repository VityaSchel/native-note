import Foundation
import SQLCipher

private nonisolated let transientBinding = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated enum SQLiteError: Error, Equatable {
	case cannotOpen(code: Int32, message: String)
	case cannotExecute(code: Int32, message: String, sql: String)
	case keyMustBe32Bytes(count: Int)
	case wrongKey
	case checkpointBlocked
}

nonisolated final class SQLiteConnection {
	let handle: OpaquePointer

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

	func scalar(_ sql: String) throws -> String? {
		let statement = try Statement(sql, on: handle)
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
		let statement = try Statement("PRAGMA wal_checkpoint(TRUNCATE)", on: handle)
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

nonisolated final class Statement {
	private let handle: OpaquePointer
	private let database: OpaquePointer
	private let sql: String

	init(_ sql: String, on database: OpaquePointer) throws {
		var prepared: OpaquePointer?
		let code = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
		guard code == SQLITE_OK, let prepared else {
			throw SQLiteError.cannotExecute(
				code: code,
				message: String(cString: sqlite3_errmsg(database)),
				sql: sql
			)
		}
		handle = prepared
		self.database = database
		self.sql = sql
	}

	deinit { sqlite3_finalize(handle) }

	func bind(_ index: Int32, _ value: Data) {
		value.withUnsafeBytes { bytes in
			_ = sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), transientBinding)
		}
	}

	func bind(_ index: Int32, _ value: String) {
		let utf8 = Array(value.utf8)
		sqlite3_bind_text(handle, index, utf8, Int32(utf8.count), transientBinding)
	}

	func bind(_ index: Int32, _ value: Int64) {
		sqlite3_bind_int64(handle, index, value)
	}

	func bindNull(_ index: Int32) {
		sqlite3_bind_null(handle, index)
	}

	@discardableResult
	func step() throws -> Bool {
		let code = sqlite3_step(handle)
		switch code {
		case SQLITE_ROW: return true
		case SQLITE_DONE: return false
		default:
			throw SQLiteError.cannotExecute(
				code: code,
				message: String(cString: sqlite3_errmsg(database)),
				sql: sql
			)
		}
	}

	func data(_ column: Int32) -> Data {
		guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
		return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
	}

	func string(_ column: Int32) -> String {
		guard let text = sqlite3_column_text(handle, column) else { return "" }
		let bytes = UnsafeRawBufferPointer(start: text, count: Int(sqlite3_column_bytes(handle, column)))
		return String(decoding: bytes, as: UTF8.self)
	}

	func int(_ column: Int32) -> Int64 {
		sqlite3_column_int64(handle, column)
	}

	func isNull(_ column: Int32) -> Bool {
		sqlite3_column_type(handle, column) == SQLITE_NULL
	}
}
