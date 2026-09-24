import Foundation
import Testing

@testable import NativeNoteKit

struct LibraryArchiveTests {
	@Test func notesSurviveTheArchive() throws {
		var edited = sampleNote(body: "Shopping\r\nbread\n---\nnot front matter")
		edited.v = 7
		let notes = [edited, sampleNote(body: ""), sampleNote(body: "Shopping")]

		let restored = try LibraryArchive.notes(in: LibraryArchive.archive(notes))

		#expect(restored.map(\.id) == notes.map(\.id))
		#expect(restored.map(\.body) == notes.map(\.body))
		#expect(restored.map(\.createdAt) == notes.map(\.createdAt))
		#expect(restored.map(\.updatedAt) == notes.map(\.updatedAt))
		#expect(restored.map(\.v) == notes.map(\.v))
	}

	@Test func aNoteRepeatedInTheArchiveIsRefused() throws {
		let note = sampleNote(body: "twice")
		let entries = ["a.md", "b.md"].map { ZipEntry(name: $0, data: Data(NoteMarkdown.render(note).utf8), modified: note.updatedAt) }

		#expect(throws: LibraryArchive.Failure.repeatedNote(note.id)) {
			try LibraryArchive.notes(in: ZipArchive.write(entries))
		}
	}

	@Test func anEntryThatIsNotTextIsRefused() throws {
		let entries = [ZipEntry(name: "binary.md", data: Data([0xff, 0xfe, 0x00]), modified: Date(epochMilliseconds: 0))]

		#expect(throws: LibraryArchive.Failure.notText("binary.md")) {
			try LibraryArchive.notes(in: ZipArchive.write(entries))
		}
	}
}
