import Foundation

@testable import NativeNoteKit

func temporaryDatabase() -> URL {
	URL.temporaryDirectory
		.appending(path: UUID().uuidString)
		.appending(path: "notes.db")
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
