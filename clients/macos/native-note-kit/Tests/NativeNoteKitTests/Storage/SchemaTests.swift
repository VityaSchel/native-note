import Foundation
import Testing

@testable import NativeNoteKit

struct SchemaTests {
	@Test func migratesOnceAndRecordsTheVersion() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		_ = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.migrations.count))

		let reopened = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.migrations.count))
		#expect(try await reopened.liveNotes().isEmpty)
	}

	@Test func aVersionOneLibraryGainsThePulledMarkAndKeepsItsNotes() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		let old = try SQLiteConnection(url: url, rawKey: databaseKey)
		try old.execute(Schema.migrations[0])
		try old.execute("PRAGMA user_version = 1")
		try old.execute("INSERT INTO note (uuid, body, createdAt, updatedAt, dirty, v) VALUES (x'00112233445566778899aabbccddeeff', 'kept', 1, 2, 1, 3)")

		let store = try await NoteStore.open(url: url, key: databaseKey)

		#expect(try await store.liveNotes().map { ($0.body, $0.v) }.elementsEqual([("kept", 3)], by: ==))
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("SELECT pulled FROM note") == "0")
	}

	@Test func refusesADatabaseFromANewerVersion() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		_ = try await openStore(at: url)
		try SQLiteConnection(url: url, rawKey: databaseKey).execute("PRAGMA user_version = \(Schema.migrations.count + 1)")

		await #expect(throws: SQLiteError.newerSchema(found: Schema.migrations.count + 1, known: Schema.migrations.count)) {
			_ = try await NoteStore.open(url: url, key: databaseKey)
		}
	}

	@Test func aFailedMigrationLeavesTheVersionUnchanged() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
		try connection.execute("CREATE TABLE note_dirty (x)")

		#expect(throws: SQLiteError.self) { try Schema.migrate(connection) }
		#expect(try connection.scalar("PRAGMA user_version") == "0")
		#expect(try connection.scalar("SELECT count(*) FROM sqlite_schema WHERE name = 'note'") == "0")
	}
}
