import Foundation
import Testing

@testable import NativeNote

private func temporaryDatabase() -> URL {
	URL.temporaryDirectory
		.appending(path: UUID().uuidString)
		.appending(path: "notes.db")
}

private func makeDirectory(for url: URL) throws {
	try FileManager.default.createDirectory(
		at: url.deletingLastPathComponent(),
		withIntermediateDirectories: true
	)
}

private let key = Data(repeating: 0x41, count: 32)

private func store(at url: URL, key: Data = key) async throws -> NoteStore {
	try makeDirectory(for: url)
	return try await NoteStore.open(url: url, key: key)
}

private func sample(body: String = "first line\nsecond line") -> Note {
	let moment = Date(epochMilliseconds: 1_760_000_000_000)
	return Note(id: UUID(), body: body, createdAt: moment, updatedAt: moment)
}

struct DatabaseEncryptionTests {
	@Test func refusesTheWrongKey() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		_ = try await store(at: url)

		await #expect(throws: SQLiteError.wrongKey) {
			_ = try await NoteStore.open(url: url, key: Data(repeating: 0x42, count: 32))
		}
	}

	@Test func leavesNoPlaintextOnDisk() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let canary = "sphinx of black quartz judge my vow"

		let notes = try await store(at: url)
		try await notes.save(sample(body: canary))

		let sidecars = [url, url.appendingPathExtension("wal"), url.appendingPathExtension("shm")]
		for file in sidecars {
			guard let bytes = try? Data(contentsOf: file) else { continue }
			#expect(!bytes.starts(with: Data("SQLite format 3".utf8)), "\(file.lastPathComponent) header")
			#expect(bytes.range(of: Data(canary.utf8)) == nil, "\(file.lastPathComponent) body")
		}

		try await notes.checkpoint()
		let checkpointed = try Data(contentsOf: url)
		#expect(checkpointed.count > 0)
		#expect(checkpointed.range(of: Data(canary.utf8)) == nil)
	}

	@Test func refusesAKeyThatIsNotThirtyTwoBytes() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)

		for count in [0, 16, 31, 33, 64] {
			#expect(throws: SQLiteError.keyMustBe32Bytes(count: count)) {
				_ = try SQLiteConnection(url: url, rawKey: Data(repeating: 0x41, count: count))
			}
		}
	}

	@Test func keepsTheKeyOutOfThrownErrors() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)
		try Data("not a database at all, but long enough to look like one".utf8).write(to: url)
		let hex = key.map { String(format: "%02x", $0) }.joined()

		var thrown = ""
		do {
			_ = try SQLiteConnection(url: url, rawKey: key)
		} catch {
			thrown = "\(error)"
		}

		#expect(!thrown.isEmpty)
		#expect(!thrown.contains(hex))
		#expect(!thrown.lowercased().contains("pragma key ="))
	}

	@Test func rekeyReplacesTheKeyAndRetiresTheOldOne() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let replacement = Data(repeating: 0x43, count: 32)
		let note = sample(body: "survives a password change")

		let notes = try await store(at: url)
		try await notes.save(note)
		try await notes.rekey(to: replacement)
		try await notes.checkpoint()

		let reopened = try await store(at: url, key: replacement)
		#expect(try await reopened.note(id: note.id)?.body == note.body)

		await #expect(throws: SQLiteError.wrongKey) {
			_ = try await NoteStore.open(url: url, key: key)
		}
	}

	@Test func rekeyRefusesAKeyThatIsNotThirtyTwoBytes() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)

		await #expect(throws: SQLiteError.keyMustBe32Bytes(count: 16)) {
			try await notes.rekey(to: Data(repeating: 0x43, count: 16))
		}
		#expect(try await notes.liveNotes().isEmpty)
	}

	@Test func appliesTheDurabilityPragmas() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)

		let connection = try SQLiteConnection(url: url, rawKey: key)

		#expect(try connection.scalar("PRAGMA journal_mode") == "wal")
		#expect(try connection.scalar("PRAGMA synchronous") == "2")
		#expect(try connection.scalar("PRAGMA fullfsync") == "1")
		#expect(try connection.scalar("PRAGMA checkpoint_fullfsync") == "1")
		#expect(try connection.scalar("PRAGMA foreign_keys") == "1")
	}
}

struct SchemaTests {
	@Test func migratesOnceAndRecordsTheVersion() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		_ = try await store(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: key).scalar("PRAGMA user_version") == "1")

		let reopened = try await store(at: url)
		#expect(try SQLiteConnection(url: url, rawKey: key).scalar("PRAGMA user_version") == "1")
		#expect(try await reopened.liveNotes().isEmpty)
	}
}

struct NoteStoreTests {
	@Test func roundTripsANoteThroughTheDatabase() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		let note = sample()

		try await notes.save(note)

		#expect(try await notes.note(id: note.id) == note)
	}

	@Test func keepsMillisecondTimestampsExactly() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		var note = sample()
		note.updatedAt = Date(epochMilliseconds: 1_760_000_000_123)

		try await notes.save(note)

		let stored = try await notes.note(id: note.id)
		#expect(stored?.updatedAt.epochMilliseconds == 1_760_000_000_123)
	}

	@Test func updatesInPlaceRatherThanInserting() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		var note = sample()

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
		let notes = try await store(at: url)
		let note = sample()
		try await notes.save(note)

		try await notes.markDeleted(id: note.id, at: Date(epochMilliseconds: 1_760_000_009_000))

		let tombstone = try await notes.note(id: note.id)
		#expect(tombstone?.deleted == true)
		#expect(tombstone?.dirty == true)
		#expect(tombstone?.body == "")
		#expect(try await notes.liveNotes().isEmpty)
	}

	@Test func aSaveNeverRevivesATombstone() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		var note = sample(body: "kayak")
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
		let notes = try await store(at: url)
		var older = sample(body: "older")
		older.updatedAt = Date(epochMilliseconds: 1_000)
		var newer = sample(body: "newer")
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
		let notes = try await store(at: url)
		let note = sample(body: "visible\u{0000}tail that must survive")

		try await notes.save(note)

		#expect(try await notes.note(id: note.id)?.body == note.body)
		#expect(try await notes.search("tail").count == 1)
	}

	@Test func roundTripsSeqAndPreservesCreatedAtAcrossResaves() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		var note = sample()
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
		let notes = try await store(at: url)
		let note = sample()
		try await notes.save(note)

		try await notes.markDeleted(id: note.id, at: Date(epochMilliseconds: 1_760_000_009_000))

		#expect(try await notes.note(id: note.id)?.updatedAt.epochMilliseconds == 1_760_000_009_000)
	}

	@Test func exposesTheFirstLineAsTheTitle() {
		#expect(sample().title == "first line")
		#expect(sample(body: "  padded  \nrest").title == "padded")
		#expect(sample(body: "single").title == "single")
	}
}

struct SearchTests {
	@Test func findsNotesByBody() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		try await notes.save(sample(body: "shopping list\nquartz and bread"))
		try await notes.save(sample(body: "meeting notes\nbudget review"))

		#expect(try await notes.search("quartz").map(\.title) == ["shopping list"])
		#expect(try await notes.search("budget").map(\.title) == ["meeting notes"])
		#expect(try await notes.search("absent").isEmpty)
	}

	@Test func treatsPunctuationAsPlainTextRatherThanQuerySyntax() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await store(at: url)
		try await notes.save(sample(body: "reply to e-mail\ndon't forget the c++ notes"))

		for term in ["don't", "e-mail", "c++", "\"", "-", "(", "*", "a,b", "AND", "OR", "NOT", "", "   "] {
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
		let notes = try await store(at: url)
		var note = sample(body: "kayak")
		try await notes.save(note)
		#expect(try await notes.search("kayak").count == 1)

		note.body = "canoe"
		try await notes.save(note)
		#expect(try await notes.search("kayak").isEmpty)
		#expect(try await notes.search("canoe").count == 1)

		try await notes.markDeleted(id: note.id, at: Date())
		#expect(try await notes.search("canoe").isEmpty)
	}
}
