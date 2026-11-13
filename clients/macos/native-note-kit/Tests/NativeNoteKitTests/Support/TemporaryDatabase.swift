import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

func temporaryDatabase(sourceLocation: SourceLocation = #_sourceLocation) -> URL {
	AppLock.databaseFile(in: temporaryDirectory(sourceLocation: sourceLocation))
}

func walFile(of database: URL) -> URL {
	URL(fileURLWithPath: database.path + "-wal")
}

func shmFile(of database: URL) -> URL {
	URL(fileURLWithPath: database.path + "-shm")
}

func makeDirectory(for url: URL) throws {
	try FileManager.default.createDirectory(
		at: url.deletingLastPathComponent(),
		withIntermediateDirectories: true
	)
}

let databaseKey = SymmetricKey(data: Data(repeating: 0x41, count: 32))

func openStore(at url: URL, key: SymmetricKey = databaseKey) async throws -> NoteStore {
	try makeDirectory(for: url)
	return try await NoteStore.create(url: url, key: key)
}

func sampleNote(body: String = "first line\nsecond line") -> Note {
	let moment: Int64 = 1_760_000_000_000
	return Note(id: UUID(), body: body, createdAt: moment, updatedAt: moment)
}
