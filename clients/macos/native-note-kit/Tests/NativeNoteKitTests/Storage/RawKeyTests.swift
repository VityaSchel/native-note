import CryptoKit
import Foundation
import SQLCipher
import Testing

@testable import NativeNoteKit

private struct Refused: Error, Equatable {
	let code: Int32
}

private func literal(_ key: SymmetricKey) -> String {
	"x'" + key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } + "'"
}

@discardableResult
private func throughThePragma(_ url: URL, key: String, _ statements: [String]) throws -> String? {
	var handle: OpaquePointer?
	defer { sqlite3_close_v2(handle) }
	guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
		throw Refused(code: sqlite3_errcode(handle))
	}
	var last: String?
	for sql in ["PRAGMA key = \"\(key)\""] + statements {
		var statement: OpaquePointer?
		defer { sqlite3_finalize(statement) }
		var code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
		while code == SQLITE_OK || code == SQLITE_ROW {
			code = sqlite3_step(statement)
			if code == SQLITE_ROW { last = sqlite3_column_text(statement, 0).map { String(cString: $0) } }
		}
		guard code == SQLITE_DONE else { throw Refused(code: code) }
	}
	return last
}

struct RawKeyTests {
	private let replacement = SymmetricKey(data: Data(repeating: 0x43, count: 32))

	private func database() throws -> URL {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		return url
	}

	@Test func theKeyReachesSQLCipherAsTheRawKeyLiteral() {
		let key = SymmetricKey(data: Data((0 ..< 4).flatMap { _ in [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef] as [UInt8] }))

		let passed = SQLiteConnection.withRawKeyLiteral(key) { String(decoding: $0, as: UTF8.self) }

		#expect(passed == "x'" + String(repeating: "0123456789abcdef", count: 4) + "'")
		#expect(passed.utf8.count == 67)
	}

	@Test func aLibraryKeyedThroughThePragmaOpensWithTheSameKey() throws {
		let url = try database()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try throughThePragma(url, key: literal(databaseKey), ["CREATE TABLE kept (x)", "INSERT INTO kept VALUES ('keyed through the pragma')"])

		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(try connection.scalar("SELECT x FROM kept") == "keyed through the pragma")
	}

	@Test func aLibraryKeyedDirectlyOpensThroughThePragma() throws {
		let url = try database()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		do {
			let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
			try connection.execute("CREATE TABLE kept (x); INSERT INTO kept VALUES ('keyed directly')")
		}

		#expect(try throughThePragma(url, key: literal(databaseKey), ["SELECT x FROM kept"]) == "keyed directly")
	}

	@Test func aRekeyOpensThroughThePragmaWithOnlyTheNewKey() throws {
		let url = try database()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		do {
			let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
			try connection.execute("CREATE TABLE kept (x); INSERT INTO kept VALUES ('rekeyed directly')")
			try connection.rekey(to: replacement)
		}

		#expect(try throughThePragma(url, key: literal(replacement), ["SELECT x FROM kept"]) == "rekeyed directly")
		#expect(throws: Refused(code: SQLITE_NOTADB)) {
			try throughThePragma(url, key: literal(databaseKey), ["SELECT x FROM kept"])
		}
	}

	@Test func aRekeyThroughThePragmaOpensWithOnlyTheNewKey() throws {
		let url = try database()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try throughThePragma(url, key: literal(databaseKey), [
			"CREATE TABLE kept (x)",
			"INSERT INTO kept VALUES ('rekeyed through the pragma')",
			"PRAGMA rekey = \"\(literal(replacement))\"",
		])

		#expect(try SQLiteConnection(url: url, rawKey: replacement).scalar("SELECT x FROM kept") == "rekeyed through the pragma")
		#expect(throws: SQLiteError.wrongKey) {
			_ = try SQLiteConnection(url: url, rawKey: databaseKey)
		}
	}

	@Test func theKeyIsNeverTakenAsAPassphrase() throws {
		let url = try database()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let passphrase = String(literal(databaseKey).dropFirst(2).dropLast())
		try throughThePragma(url, key: passphrase, ["CREATE TABLE kept (x)"])

		#expect(throws: SQLiteError.wrongKey) {
			_ = try SQLiteConnection(url: url, rawKey: databaseKey)
		}
	}
}
