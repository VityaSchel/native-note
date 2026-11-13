import Foundation
import Testing

@testable import NativeNoteKit

private struct Planted: Error {}

@Suite(.scratch)
struct SQLiteConnectionTests {
	@Test func refusesAPathItCannotOpen() throws {
		let url = temporaryDatabase()

		#expect(throws: SQLiteError.cannotOpen(code: 14, message: "unable to open database file")) {
			_ = try SQLiteConnection(url: url, rawKey: databaseKey)
		}
		#expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
	}

	@Test func aThrowingTransactionRollsBackAndRethrows() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
		let probeCount = "SELECT count(*) FROM sqlite_schema WHERE name = 'probe'"

		#expect(throws: Planted.self) {
			try connection.transaction {
				try connection.execute("CREATE TABLE probe (x)")
				throw Planted()
			}
		}
		#expect(try connection.scalar(probeCount) == "0")

		try connection.transaction { try connection.execute("CREATE TABLE probe (x)") }
		#expect(try connection.scalar(probeCount) == "1")
	}

	@Test func executeReportsTheStatementThatFailed() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(throws: SQLiteError.cannotExecute(code: 1, message: "near \"SELEC\": syntax error", sql: "SELEC 1")) {
			try connection.execute("SELEC 1")
		}
	}

	@Test func aDatabaseHeldExclusivelyIsBusyRatherThanAWrongKey() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let holder = try SQLiteConnection(url: url, rawKey: databaseKey)
		try holder.execute("PRAGMA locking_mode = EXCLUSIVE")
		try holder.execute("BEGIN EXCLUSIVE")
		try holder.execute("CREATE TABLE held (x)")

		#expect(throws: SQLiteError.cannotExecute(code: 5, message: "database is locked", sql: "SELECT count(*) FROM sqlite_schema")) {
			_ = try SQLiteConnection(url: url, rawKey: databaseKey)
		}
		try holder.execute("ROLLBACK")
	}

	@Test func aWriteWaitsForAnotherConnectionsTransaction() async throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let waiting = try SQLiteConnection(url: url, rawKey: databaseKey)
		try waiting.execute("CREATE TABLE written (x)")
		#expect(try waiting.scalar("PRAGMA busy_timeout") == "5000")
		let holds = AsyncStream<Void>.makeStream()
		let holding = Task.detached {
			defer { holds.continuation.finish() }
			let holder = try SQLiteConnection(url: url, rawKey: databaseKey, create: false)
			try holder.execute("BEGIN IMMEDIATE")
			try holder.execute("INSERT INTO written VALUES ('holder')")
			holds.continuation.yield()
			try await Task.sleep(for: .milliseconds(300))
			try holder.execute("COMMIT")
		}
		for await _ in holds.stream { break }

		try waiting.execute("INSERT INTO written VALUES ('waiter')")

		try await holding.value
		#expect(try waiting.scalar("SELECT group_concat(x) FROM written") == "holder,waiter")
	}

	@Test func anEmptyBlobBindsAsABlobNotNull() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let statement = try SQLiteConnection(url: url, rawKey: databaseKey).prepare("SELECT typeof(?1), typeof(?2), length(?1)")

		try statement.bind(1, Data())
		try statement.bind(2, "")

		#expect(try statement.step())
		#expect(statement.string(0) == "blob")
		#expect(statement.string(1) == "text")
		#expect(statement.int(2) == 0)
	}

	@Test func aBindingThatDoesNotLandIsAnError() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let statement = try SQLiteConnection(url: url, rawKey: databaseKey).prepare("SELECT ?1")

		#expect(throws: SQLiteError.cannotExecute(code: 25, message: "bad parameter or other API misuse", sql: "SELECT ?1")) {
			try statement.bind(2, Data([1]))
		}
		#expect(throws: SQLiteError.self) { try statement.bind(2, "text") }
		#expect(throws: SQLiteError.self) { try statement.bind(2, Int64(1)) }
		#expect(throws: SQLiteError.self) { try statement.bind(2, Data()) }
	}

	@Test func scalarWithoutARowIsNil() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(try connection.scalar("SELECT 1 WHERE 0") == nil)
		#expect(try connection.scalar("SELECT NULL") == "")
	}

	@Test func nullColumnsReadAsEmpty() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let statement = try SQLiteConnection(url: url, rawKey: databaseKey)
			.prepare("SELECT missing, missing, typeof(missing) FROM (SELECT NULL AS missing)")

		#expect(try statement.step())
		#expect(statement.data(0).isEmpty)
		#expect(statement.string(1).isEmpty)
		#expect(statement.string(2) == "null")
	}
}
