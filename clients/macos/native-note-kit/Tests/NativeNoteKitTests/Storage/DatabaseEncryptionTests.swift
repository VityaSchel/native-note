import Foundation
import Testing

@testable import NativeNoteKit

struct DatabaseEncryptionTests {
	@Test func refusesTheWrongKey() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		_ = try await openStore(at: url)

		await #expect(throws: SQLiteError.wrongKey) {
			_ = try await NoteStore.open(url: url, key: Data(repeating: 0x42, count: 32))
		}
	}

	@Test func leavesNoPlaintextOnDisk() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let canary = "sphinx of black quartz judge my vow"

		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: canary))

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
		let hex = databaseKey.map { String(format: "%02x", $0) }.joined()

		var thrown = ""
		do {
			_ = try SQLiteConnection(url: url, rawKey: databaseKey)
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
		let note = sampleNote(body: "survives a password change")

		let notes = try await openStore(at: url)
		try await notes.save(note)
		try await notes.rekey(to: replacement)
		try await notes.checkpoint()

		let reopened = try await openStore(at: url, key: replacement)
		#expect(try await reopened.note(id: note.id)?.body == note.body)

		await #expect(throws: SQLiteError.wrongKey) {
			_ = try await NoteStore.open(url: url, key: databaseKey)
		}
	}

	@Test func rekeyRefusesAKeyThatIsNotThirtyTwoBytes() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)

		await #expect(throws: SQLiteError.keyMustBe32Bytes(count: 16)) {
			try await notes.rekey(to: Data(repeating: 0x43, count: 16))
		}
		#expect(try await notes.liveNotes().isEmpty)
	}

	@Test func appliesTheDurabilityPragmas() throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		try makeDirectory(for: url)

		let connection = try SQLiteConnection(url: url, rawKey: databaseKey)

		#expect(try connection.scalar("PRAGMA journal_mode") == "wal")
		#expect(try connection.scalar("PRAGMA synchronous") == "2")
		#expect(try connection.scalar("PRAGMA fullfsync") == "1")
		#expect(try connection.scalar("PRAGMA checkpoint_fullfsync") == "1")
		#expect(try connection.scalar("PRAGMA foreign_keys") == "1")
	}
}
