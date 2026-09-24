import Foundation

@testable import NativeNoteKit

func temporaryDirectory() -> URL {
	URL.temporaryDirectory.appending(path: UUID().uuidString)
}

func temporaryDatabase() -> URL {
	AppLock.databaseFile(in: temporaryDirectory())
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

let databaseKey = Data(repeating: 0x41, count: 32)

func openStore(at url: URL, key: Data = databaseKey) async throws -> NoteStore {
	try makeDirectory(for: url)
	return try await NoteStore.open(url: url, key: key)
}

func sampleNote(body: String = "first line\nsecond line") -> Note {
	let moment = Date(epochMilliseconds: 1_760_000_000_000)
	return Note(id: UUID(), body: body, createdAt: moment, updatedAt: moment)
}
