import Foundation
import Testing

@testable import NativeNoteKit

@Suite(.scratch)
struct SchemaTests {
	@Test func createsTheSchemaOnceAndRecordsItsVersion() async throws {
		let url = temporaryDatabase()

		_ = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.version))

		let reopened = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.version))
		#expect(try await reopened.liveNotes().isEmpty)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("SELECT group_concat(name, ',') FROM pragma_table_info('note')") == "uuid,body,createdAt,updatedAt,deleted,dirty,v,pulled,ext")
	}

	@Test func refusesADatabaseFromANewerVersion() async throws {
		let url = temporaryDatabase()
		_ = try await openStore(at: url)
		try SQLiteConnection(url: url, rawKey: databaseKey).execute("PRAGMA user_version = \(Schema.version + 1)")

		await #expect(throws: SQLiteError.newerSchema(found: Schema.version + 1, known: Schema.version)) {
			_ = try await NoteStore.open(url: url, key: databaseKey)
		}
	}

	@Test func aFailedCreationLeavesTheVersionUnchanged() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
		try connection.execute("CREATE TABLE note_dirty (x)")

		#expect(throws: SQLiteError.self) { try Schema.prepare(connection) }
		#expect(try connection.scalar("PRAGMA user_version") == "0")
		#expect(try connection.scalar("SELECT count(*) FROM sqlite_schema WHERE name = 'note'") == "0")
	}
}
