import Foundation
import Testing

@testable import NativeNoteKit

struct SchemaTests {
	@Test func migratesOnceAndRecordsTheVersion() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		_ = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == "1")

		let reopened = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == "1")
		#expect(try await reopened.liveNotes().isEmpty)
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
}
