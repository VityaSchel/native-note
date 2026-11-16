import Foundation
import Testing

@testable import NativeNoteKit

@Suite(.scratch)
struct SchemaTests {
	@Test func migratesOnceAndRecordsTheVersion() async throws {
		let url = temporaryDatabase()

		_ = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.migrations.count))

		let reopened = try await openStore(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("PRAGMA user_version") == String(Schema.migrations.count))
		#expect(try await reopened.liveNotes().isEmpty)
	}

	@Test func aVersionOneLibraryGainsThePulledMarkAndKeepsItsNotes() async throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let old = try SQLiteConnection(url: url, rawKey: databaseKey)
		try old.execute(Schema.migrations[0])
		try old.execute("PRAGMA user_version = 1")
		try old.execute("INSERT INTO note (uuid, body, createdAt, updatedAt, dirty, v) VALUES (x'00112233445566778899aabbccddeeff', 'kept', 1, 2, 1, 3)")

		let store = try await NoteStore.open(url: url, key: databaseKey)

		#expect(try await store.liveNotes().map { ($0.body, $0.v) }.elementsEqual([("kept", 3)], by: ==))
		#expect(try SQLiteConnection(url: url, rawKey: databaseKey).scalar("SELECT pulled FROM note") == "0")
		#expect(try await store.liveNotes().map(\.ext) == [Data()])
		#expect(try noteColumns(url) == Self.currentColumns)
	}

	private static let currentColumns = "uuid,body,createdAt,updatedAt,deleted,dirty,v,pulled,ext"

	private func noteColumns(_ url: URL) throws -> String? {
		try SQLiteConnection(url: url, rawKey: databaseKey).scalar("SELECT group_concat(name, ',') FROM pragma_table_info('note')")
	}

	@Test func aVersionTwoLibraryGainsAnEmptyExtDropsSeqAndKeepsEveryNoteItsSyncStateAndItsSearch() async throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let old = try SQLiteConnection(url: url, rawKey: databaseKey)
		try old.execute(Schema.migrations[0])
		try old.execute(Schema.migrations[1])
		try old.execute("PRAGMA user_version = 2")
		try old.execute("""
			INSERT INTO note (uuid, body, createdAt, updatedAt, deleted, dirty, v, seq, pulled) VALUES
				(x'00000000000040008000000000000001', 'pulled lighthouse', 1, 2, 0, 0, 4, 17, 1),
				(x'00000000000040008000000000000002', 'edited ferry, waiting to push', 3, 4, 0, 1, 2, NULL, 0),
				(x'00000000000040008000000000000003', '', 5, 6, 1, 1, 7, NULL, 0);
			INSERT INTO meta (k, v) VALUES ('since', x'0000000000000011'), ('pin', x'00000003');
			""")
		let ids = (1 ... 3).map { UUID(uuidString: "00000000-0000-4000-8000-00000000000\($0)")! }

		let store = try await NoteStore.open(url: url, key: databaseKey)

		#expect(try await store.note(id: ids[0]) == Note(id: ids[0], body: "pulled lighthouse", createdAt: 1, updatedAt: 2, v: 4))
		#expect(try await store.note(id: ids[1]) == Note(id: ids[1], body: "edited ferry, waiting to push", createdAt: 3, updatedAt: 4, dirty: true, v: 2))
		#expect(try await store.note(id: ids[2]) == Note(id: ids[2], body: "", createdAt: 5, updatedAt: 6, deleted: true, dirty: true, v: 7))
		#expect(try await store.pendingPushes().map(\.id).sorted { $0.uuidString < $1.uuidString } == [ids[1], ids[2]])
		#expect(try await store.since() == 17)
		#expect(try await store.pin() == 3)
		let migrated = try SQLiteConnection(url: url, rawKey: databaseKey)
		#expect(try migrated.scalar("PRAGMA user_version") == String(Schema.migrations.count))
		#expect(try migrated.scalar("SELECT group_concat(pulled, ',') FROM (SELECT pulled FROM note ORDER BY uuid)") == "1,0,0")
		#expect(try noteColumns(url) == Self.currentColumns)
		#expect(try await store.search("lighthouse").map(\.id) == [ids[0]])

		var edited = try #require(try await store.note(id: ids[1]))
		edited.body = "edited bridge, waiting to push"
		try await store.save(edited)

		#expect(try await store.search("bridge").map(\.id) == [ids[1]])
		#expect(try await store.search("ferry").isEmpty)
		#expect(try migrated.scalar("PRAGMA integrity_check") == "ok")
		try migrated.execute("INSERT INTO note_fts (note_fts) VALUES ('integrity-check')")
	}

	@Test func refusesADatabaseFromANewerVersion() async throws {
		let url = temporaryDatabase()
		_ = try await openStore(at: url)
		try SQLiteConnection(url: url, rawKey: databaseKey).execute("PRAGMA user_version = \(Schema.migrations.count + 1)")

		await #expect(throws: SQLiteError.newerSchema(found: Schema.migrations.count + 1, known: Schema.migrations.count)) {
			_ = try await NoteStore.open(url: url, key: databaseKey)
		}
	}

	@Test func aFailedMigrationLeavesTheVersionUnchanged() throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)
		try connection.execute("CREATE TABLE note_dirty (x)")

		#expect(throws: SQLiteError.self) { try Schema.migrate(connection) }
		#expect(try connection.scalar("PRAGMA user_version") == "0")
		#expect(try connection.scalar("SELECT count(*) FROM sqlite_schema WHERE name = 'note'") == "0")
	}
}
