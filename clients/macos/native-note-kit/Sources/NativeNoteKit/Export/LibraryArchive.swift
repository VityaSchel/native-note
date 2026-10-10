import Foundation

nonisolated enum LibraryArchive {
	enum Failure: Error, Equatable {
		case notText(String)
		case repeatedNote(UUID)
		case tooLarge
	}

	static let maximumSize = 512 * 1024 * 1024

	static func archive(_ notes: [Note]) throws -> Data {
		let entries = zip(notes, NoteMarkdown.fileNames(for: notes)).map { note, name in
			ZipEntry(name: name, data: Data(NoteMarkdown.render(note).utf8), modified: note.updatedAt)
		}
		return try ZipArchive.write(entries)
	}

	static func importable(_ file: Data) throws -> Data {
		guard file.count <= maximumSize else { throw ZipArchive.Failure.tooLarge }
		return file
	}

	static func notes(in archive: Data) throws -> [Note] {
		var seen = Set<UUID>()
		return try ZipArchive.read(archive).map { entry in
			guard let text = String(data: entry.data, encoding: .utf8) else { throw Failure.notText(entry.name) }
			let note = try NoteMarkdown.parse(text)
			guard seen.insert(note.id).inserted else { throw Failure.repeatedNote(note.id) }
			return note
		}
	}
}
