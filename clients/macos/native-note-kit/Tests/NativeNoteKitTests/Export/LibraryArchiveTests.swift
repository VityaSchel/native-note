import Foundation
import Testing

@testable import NativeNoteKit

struct LibraryArchiveTests {
	@Test func notesSurviveTheArchiveAndComeBackUnsynced() throws {
		var edited = sampleNote(body: "Shopping\r\nbread\n---\nnot front matter")
		edited.v = 7
		edited.ext = Data([0x65, 0x78, 0x74])
		let notes = [edited, sampleNote(body: ""), sampleNote(body: "Shopping")]

		let restored = try LibraryArchive.notes(in: LibraryArchive.archive(notes))

		#expect(restored.map(\.id) == notes.map(\.id))
		#expect(restored.map(\.body) == notes.map(\.body))
		#expect(restored.map(\.createdAt) == notes.map(\.createdAt))
		#expect(restored.map(\.updatedAt) == notes.map(\.updatedAt))
		#expect(restored.allSatisfy { $0.v == 0 && $0.ext.isEmpty && $0.dirty })
	}

	@Test func anExportImportWouldRefuseIsNotWritten() throws {
		#expect(try LibraryArchive.importable(Data(count: LibraryArchive.maximumSize)).count == LibraryArchive.maximumSize)
		#expect(throws: ZipArchive.Failure.tooLarge) {
			try LibraryArchive.importable(Data(count: LibraryArchive.maximumSize + 1))
		}
	}

	@Test func aNoteRepeatedInTheArchiveIsRefused() throws {
		let note = sampleNote(body: "twice")
		let entries = ["a.md", "b.md"].map { ZipEntry(name: $0, data: Data(NoteMarkdown.render(note).utf8), modified: note.updated) }

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
