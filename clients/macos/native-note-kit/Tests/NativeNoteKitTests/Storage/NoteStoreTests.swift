import Foundation
import Testing

@testable import NativeNoteKit

struct NoteStoreTests {
	@Test func roundTripsANoteThroughTheDatabase() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		let note = sampleNote()

		try await notes.save(note)

		#expect(try await notes.note(id: note.id) == note)
	}

	@Test func keepsMillisecondTimestampsExactly() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote()
		note.updatedAt = Date(epochMilliseconds: 1_760_000_000_123)

		try await notes.save(note)

		let stored = try await notes.note(id: note.id)
		#expect(stored?.updatedAt.epochMilliseconds == 1_760_000_000_123)
	}

	@Test func updatesInPlaceRatherThanInserting() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote()

		try await notes.save(note)
		note.body = "rewritten"
		note.v = 2
		try await notes.save(note)

		#expect(try await notes.liveNotes().count == 1)
		#expect(try await notes.note(id: note.id)?.body == "rewritten")
		#expect(try await notes.note(id: note.id)?.v == 2)
	}

	@Test func deletionSetsAFlagInsteadOfRemovingTheRow() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		let note = sampleNote()
		try await notes.save(note)

		try await notes.markDeleted(id: note.id, at: Date(epochMilliseconds: 1_760_000_009_000))

		let tombstone = try await notes.note(id: note.id)
		#expect(tombstone?.deleted == true)
		#expect(tombstone?.dirty == true)
		#expect(tombstone?.body == "")
		#expect(try await notes.liveNotes().isEmpty)
	}

	@Test func closingReleasesTheDatabase() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote())
		#expect(FileManager.default.fileExists(atPath: url.path + "-wal"))

		await notes.close()

		#expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
		await #expect(throws: SQLiteError.closed) { try await notes.liveNotes() }
	}

	@Test func aSaveNeverRevivesATombstone() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote(body: "kayak")
		try await notes.save(note)
		try await notes.markDeleted(id: note.id, at: Date(epochMilliseconds: 1_760_000_009_000))

		note.body = "kayak, typed before the delete"
		try await notes.save(note)

		let tombstone = try await notes.note(id: note.id)
		#expect(tombstone?.deleted == true)
		#expect(tombstone?.body == "")
		#expect(try await notes.search("kayak").isEmpty)
	}

	@Test func listsNewestFirstAndReportsPendingPushes() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var older = sampleNote(body: "older")
		older.updatedAt = Date(epochMilliseconds: 1_000)
		var newer = sampleNote(body: "newer")
		newer.updatedAt = Date(epochMilliseconds: 2_000)
		newer.dirty = true

		try await notes.save(older)
		try await notes.save(newer)

		#expect(try await notes.liveNotes().map(\.body) == ["newer", "older"])
		#expect(try await notes.pendingPushes().map(\.body) == ["newer"])
	}

	@Test func keepsBodiesWithEmbeddedNulIntact() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		let note = sampleNote(body: "visible\u{0000}tail that must survive")

		try await notes.save(note)

		#expect(try await notes.note(id: note.id)?.body == note.body)
		#expect(try await notes.search("tail").count == 1)
	}

	@Test func roundTripsSeqAndPreservesCreatedAtAcrossResaves() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote()
		note.seq = 4_294_967_296

		try await notes.save(note)
		#expect(try await notes.note(id: note.id)?.seq == 4_294_967_296)

		let created = note.createdAt
		note.createdAt = Date(epochMilliseconds: 1)
		note.body = "edited"
		try await notes.save(note)

		#expect(try await notes.note(id: note.id)?.createdAt == created)
		#expect(try await notes.note(id: note.id)?.seq == 4_294_967_296)
	}

	@Test func deletionStampsTheSuppliedMoment() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		let note = sampleNote()
		try await notes.save(note)

		try await notes.markDeleted(id: note.id, at: Date(epochMilliseconds: 1_760_000_009_000))

		#expect(try await notes.note(id: note.id)?.updatedAt.epochMilliseconds == 1_760_000_009_000)
	}

	@Test func aMissingNoteReadsAsNil() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)

		#expect(try await notes.note(id: UUID()) == nil)
	}

	@Test func aRowWithAMalformedIdIsSkipped() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote())

		try SQLiteConnection(url: url, rawKey: databaseKey)
			.execute("INSERT INTO note (uuid, body, createdAt, updatedAt) VALUES (x'00', 'orphan', 0, 0)")

		#expect(try await notes.liveNotes().map(\.body) == [sampleNote().body])
	}

	@Test func findsNotesByBody() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: "shopping list\nquartz and bread"))
		try await notes.save(sampleNote(body: "meeting notes\nbudget review"))

		#expect(try await notes.search("quartz").map(\.title) == ["shopping list"])
		#expect(try await notes.search("budget").map(\.title) == ["meeting notes"])
		#expect(try await notes.search("absent").isEmpty)
	}

	@Test func treatsPunctuationAsPlainTextRatherThanQuerySyntax() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: "reply to e-mail\ndon't forget the c++ notes"))

		for term in ["don't", "e-mail", "c++", "\"", "-", "(", "*", "a,b", "AND", "OR", "NOT", "", "   ", "\u{0D4E}\"", "kayak \u{0D4E}\""] {
			await #expect(throws: Never.self, "search(\(term)) must not throw") {
				_ = try await notes.search(term)
			}
		}

		#expect(try await notes.search("e-mail").count == 1)
		#expect(try await notes.search("don't").count == 1)
		#expect(try await notes.search("").isEmpty)
		#expect(try await notes.search("   ").isEmpty)
	}

	@Test func followsEditsAndDeletions() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote(body: "kayak")
		try await notes.save(note)
		#expect(try await notes.search("kayak").count == 1)

		note.body = "canoe"
		try await notes.save(note)
		#expect(try await notes.search("kayak").isEmpty)
		#expect(try await notes.search("canoe").count == 1)

		try await notes.markDeleted(id: note.id, at: Date())
		#expect(try await notes.search("canoe").isEmpty)
	}

	@Test func matchesAPrefixOfTheLastWordOnly() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: "kayak trip"))

		#expect(try await notes.search("kay").count == 1)
		#expect(try await notes.search("kayak tr").count == 1)
		#expect(try await notes.search("kay trip").isEmpty)
	}
}
