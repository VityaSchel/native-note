import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

enum PrebuiltLibrary {
	static let key = SymmetricKey(data: Data(0 ..< 32))
	static let moment: Int64 = 1_760_000_000_000

	static let recipe = Note(
		id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000001")!,
		body: "Crème brûlée\nsix yolks, cream, one vanilla bean",
		createdAt: moment,
		updatedAt: moment + 1,
		dirty: true
	)
	static let crossing = Note(
		id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000002")!,
		body: "Evening crossing\npelicans over the lighthouse",
		createdAt: moment + 2,
		updatedAt: moment + 3,
		v: 3
	)
	static let standup = Note(
		id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000003")!,
		body: "Standup\nshipped the storage layer",
		createdAt: moment + 4,
		updatedAt: moment + 6,
		dirty: true
	)
	static let wordEditedAway = "paperwork"
	static let meeting = Note(
		id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000004")!,
		body: "Встреча с командой\nобсудить выпуск",
		createdAt: moment + 7,
		updatedAt: moment + 7,
		dirty: true
	)
	static let removed = Note(
		id: UUID(uuidString: "5A1E0000-0000-4000-8000-000000000005")!,
		body: "",
		createdAt: moment + 8,
		updatedAt: moment + 9,
		deleted: true,
		dirty: true
	)
	static let wordOfDeletedNote = "hunter2"
	static let notes = [recipe, crossing, standup, meeting]

	static let server = URL(string: "https://notes.example/sync")!
	static let apiKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
	static let contentKey = SymmetricKey(data: Data(repeating: 0xC3, count: 32))
	static let pin: UInt32 = 7

	static let corpusCount = 12
	static let corpusDigest = "d1088ef2267e32e1701b30c90b7f537665c55ff59b9a4fc6a0699f3bea6c7620"

	static func corpusID(_ index: Int) -> UUID {
		UUID(uuidString: String(format: "C0E90000-0000-4000-8000-%012X", index))!
	}

	static func digest(_ bodies: [String]) -> String {
		var hash = SHA256()
		for body in bodies {
			let bytes = Data(body.utf8)
			hash.update(data: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) })
			hash.update(data: bytes)
		}
		return hash.finalize().map { String(format: "%02x", $0) }.joined()
	}
}

private func bytes(_ key: SymmetricKey?) -> Data? {
	key?.withUnsafeBytes { Data($0) }
}

@Suite(.scratch)
struct PrebuiltLibraryTests {
	private func copiedLibrary() throws -> URL {
		let fixture = try #require(Bundle.module.url(forResource: "fixtures", withExtension: nil)).appending(path: "prebuilt-sqlcipher-4.17.0.db")
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		try FileManager.default.copyItem(at: fixture, to: url)
		return url
	}

	@Test func opensWithItsKeyAndKeepsEveryNote() async throws {
		let url = try copiedLibrary()

		let store = try await NoteStore.open(url: url, key: PrebuiltLibrary.key)

		for note in PrebuiltLibrary.notes + [PrebuiltLibrary.removed] {
			#expect(try await store.note(id: note.id) == note)
		}
		let corpus = try await store.liveNotes()
			.filter { $0.id.uuidString.hasPrefix("C0E90000") }
			.sorted { $0.createdAt < $1.createdAt }
		#expect(corpus.map(\.id) == (0 ..< PrebuiltLibrary.corpusCount).map(PrebuiltLibrary.corpusID))
		#expect(PrebuiltLibrary.digest(corpus.map(\.body)) == PrebuiltLibrary.corpusDigest)

		let settings = try #require(try await store.syncSettings())
		#expect(settings.server == PrebuiltLibrary.server)
		#expect(bytes(settings.apiKey) == bytes(PrebuiltLibrary.apiKey))
		#expect(bytes(settings.contentKey) == bytes(PrebuiltLibrary.contentKey))
		#expect(try await store.pin() == PrebuiltLibrary.pin)
		#expect(try await store.since() == 0)
	}

	@Test func searchesTheIndexItWasWrittenWith() async throws {
		let url = try copiedLibrary()

		let store = try await NoteStore.open(url: url, key: PrebuiltLibrary.key)

		#expect(try await store.search("brulee").map(\.id) == [PrebuiltLibrary.recipe.id])
		#expect(try await store.search("pelic").map(\.id) == [PrebuiltLibrary.crossing.id])
		#expect(try await store.search("ОБСУДИТЬ").map(\.id) == [PrebuiltLibrary.meeting.id])
		#expect(try await store.search("shipped storage").map(\.id) == [PrebuiltLibrary.standup.id])
		#expect(try await store.search(PrebuiltLibrary.wordEditedAway).isEmpty)
		#expect(try await store.search(PrebuiltLibrary.wordOfDeletedNote).isEmpty)

		let connection = try SQLiteConnection(url: url, rawKey: PrebuiltLibrary.key, create: false)
		#expect(try connection.scalar("PRAGMA integrity_check") == "ok")
		try connection.execute("INSERT INTO note_fts (note_fts) VALUES ('integrity-check')")
	}

	@Test func keepsTakingEditsAndReopens() async throws {
		let url = try copiedLibrary()
		let added = sampleNote(body: "Written after the switch\nmarmalade")
		var edited = PrebuiltLibrary.recipe
		edited.body = "Crème brûlée\nseven yolks"

		let store = try await NoteStore.open(url: url, key: PrebuiltLibrary.key)
		try await store.save(added)
		try await store.save(edited)
		await store.close()

		let reopened = try await NoteStore.open(url: url, key: PrebuiltLibrary.key)
		#expect(try await reopened.note(id: added.id) == added)
		#expect(try await reopened.search("marmalade").map(\.id) == [added.id])
		#expect(try await reopened.search("seven").map(\.id) == [PrebuiltLibrary.recipe.id])
		#expect(try await reopened.search("vanilla").isEmpty)
		#expect(try await reopened.note(id: PrebuiltLibrary.crossing.id) == PrebuiltLibrary.crossing)
		let connection = try SQLiteConnection(url: url, rawKey: PrebuiltLibrary.key, create: false)
		#expect(try connection.scalar("PRAGMA integrity_check") == "ok")
		try connection.execute("INSERT INTO note_fts (note_fts) VALUES ('integrity-check')")
	}

	@Test func refusesAnyOtherKey() async throws {
		let url = try copiedLibrary()

		await #expect(throws: SQLiteError.wrongKey) {
			_ = try await NoteStore.open(url: url, key: databaseKey)
		}
	}
}
