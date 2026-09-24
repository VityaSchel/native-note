import Foundation
import Testing

@testable import NativeNoteKit

private struct Planted: Error {}

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
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
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
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(throws: SQLiteError.cannotExecute(code: 1, message: "near \"SELEC\": syntax error", sql: "SELEC 1")) {
			try connection.execute("SELEC 1")
		}
	}

	@Test func aDatabaseHeldExclusivelyIsBusyRatherThanAWrongKey() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
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

	@Test func aCheckpointBlockedByAReaderSaysSo() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote())
		let reader = try SQLiteConnection(url: url, rawKey: databaseKey)
		try reader.execute("BEGIN")
		_ = try reader.scalar("SELECT count(*) FROM note")

		try await notes.save(sampleNote(body: "second"))

		await #expect(throws: SQLiteError.checkpointBlocked) { try await notes.checkpoint() }
		try reader.execute("COMMIT")
	}

	@Test func scalarWithoutARowIsNil() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(try connection.scalar("SELECT 1 WHERE 0") == nil)
		#expect(try connection.scalar("SELECT NULL") == "")
	}

	@Test func nullColumnsReadAsEmpty() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		let statement = try SQLiteConnection(url: url, rawKey: databaseKey).prepare("SELECT NULL, NULL")

		#expect(try statement.step())
		#expect(statement.data(0).isEmpty)
		#expect(statement.string(1).isEmpty)
		#expect(statement.isNull(0))
	}
}
