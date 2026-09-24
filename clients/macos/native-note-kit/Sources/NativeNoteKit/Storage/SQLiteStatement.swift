import Foundation
import SQLCipher

private nonisolated let transientBinding = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated final class SQLiteStatement {
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
