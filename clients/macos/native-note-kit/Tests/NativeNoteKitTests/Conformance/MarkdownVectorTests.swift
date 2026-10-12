import Foundation
import Testing

@testable import NativeNoteKit

struct MarkdownVectorTests {
	@Test func everyCaseRendersToItsFileAndParsesBack() throws {
		let cases = try Vectors.load(.markdown)
		#expect(!cases.isEmpty)

		for vector in cases {
			let note = Note(
				id: try #require(UUID(bytes: vector.require("uuid"))),
				body: try #require(vector.string("body")),
				createdAt: Int64(try #require(vector.int("createdAt"))),
				updatedAt: Int64(try #require(vector.int("updatedAt"))),
				dirty: true,
				v: UInt32(try #require(vector.int("v")))
			)
			let file = try #require(vector.string("markdown"))

			#expect(Array(NoteMarkdown.render(note).utf8) == Array(file.utf8), "case \(vector.name)")
			#expect(try NoteMarkdown.parse(file) == note, "case \(vector.name)")
		}
	}
}
