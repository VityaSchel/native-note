import Foundation
import Testing

@testable import NativeNoteKit

struct SearchTests {
	@Test func findsNotesByBody() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: "shopping list\nquartz and bread"))
		try await notes.save(sampleNote(body: "meeting notes\nbudget review"))

		#expect(try await notes.search("quartz").map(\.title) == ["shopping list"])
		#expect(try await notes.search("budget").map(\.title) == ["meeting notes"])
		#expect(try await notes.search("absent").isEmpty)
	}

	@Test func treatsPunctuationAsPlainTextRatherThanQuerySyntax() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		try await notes.save(sampleNote(body: "reply to e-mail\ndon't forget the c++ notes"))

		for term in ["don't", "e-mail", "c++", "\"", "-", "(", "*", "a,b", "AND", "OR", "NOT", "", "   "] {
			await #expect(throws: Never.self, "search(\(term)) must not throw") {
				_ = try await notes.search(term)
			}
		}

		#expect(try await notes.search("e-mail").count == 1)
		#expect(try await notes.search("don't").count == 1)
		#expect(try await notes.search("").isEmpty)
		#expect(try await notes.search("   ").isEmpty)
	}

	@Test func followsEditsAndDeletions() async throws {
		let url = temporaryDatabase()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
		let notes = try await openStore(at: url)
		var note = sampleNote(body: "kayak")
		try await notes.save(note)
		#expect(try await notes.search("kayak").count == 1)

		note.body = "canoe"
		try await notes.save(note)
		#expect(try await notes.search("kayak").isEmpty)
		#expect(try await notes.search("canoe").count == 1)

		try await notes.markDeleted(id: note.id, at: Date())
		#expect(try await notes.search("canoe").isEmpty)
	}
}
