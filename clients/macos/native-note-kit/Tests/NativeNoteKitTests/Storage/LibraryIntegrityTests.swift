import Foundation
import Testing

@testable import NativeNoteKit

struct LibraryIntegrityTests {
	private func library(notes: Int) async throws -> URL {
		let directory = temporaryDirectory()
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		let store = try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey())
		for index in 0 ..< notes {
			try await store.save(sampleNote(body: String(repeating: "note \(index) ", count: 400)))
		}
		await store.close()
		return directory
	}

	@Test func aClosedLibraryChecksOK() async throws {
		let directory = try await library(notes: 3)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(try await LibraryIntegrity.check(libraryAt: directory, password: workspacePassword) == "ok")
	}

	@Test func theWrongPasswordOpensNothing() async throws {
		let directory = try await library(notes: 1)
		defer { try? FileManager.default.removeItem(at: directory) }

		await #expect(throws: SQLiteError.wrongKey) {
			try await LibraryIntegrity.check(libraryAt: directory, password: "wrong horse")
		}
	}

	@Test func theWALHeaderCountsTheCheckpointsItRestartedAfter() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		#expect(LibraryIntegrity.walCheckpoints(libraryAt: directory) == nil)

		var connection: SQLiteConnection? = try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: try await workspaceKey())
		try connection?.execute("CREATE TABLE typed (text TEXT)")
		#expect(LibraryIntegrity.walCheckpoints(libraryAt: directory) == 0)
		for restart in 1 ... 2 {
			_ = try connection?.scalar("PRAGMA wal_checkpoint(RESTART)")
			try connection?.execute("INSERT INTO typed VALUES ('restart \(restart)')")
			#expect(LibraryIntegrity.walCheckpoints(libraryAt: directory) == restart)
		}
		connection = nil
		#expect(LibraryIntegrity.walCheckpoints(libraryAt: directory) == nil)
	}

	@Test func aDamagedPageIsNotOK() async throws {
		let directory = try await library(notes: 40)
		defer { try? FileManager.default.removeItem(at: directory) }
		let database = try FileHandle(forUpdating: AppLock.databaseFile(in: directory))
		try database.seek(toOffset: try database.seekToEnd() / 2)
		try database.write(contentsOf: Data(repeating: 0xA5, count: 64))
		try database.close()

		let result = try? await LibraryIntegrity.check(libraryAt: directory, password: workspacePassword)

		#expect(result != "ok")
	}
}
