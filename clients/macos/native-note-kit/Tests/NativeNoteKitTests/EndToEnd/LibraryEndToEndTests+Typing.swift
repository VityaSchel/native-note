import Foundation
import Testing

@testable import NativeNoteKit

extension LibraryEndToEndTests {
	@Test func savingAndRegroupingStayFastOnAThousandNotes() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery", filled: false)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: RealisticCorpus.bodies(count: 1_000))
		let id = try #require(model.groups.first?.notes.first?.id)
		model.selection = id
		var body = try #require(model.selectedNote?.body)
		var keystrokes = Timings()
		var saves = Timings()

		for index in 0 ..< 200 {
			body += String(index % 10)
			await keystrokes.measure {
				model.edit(id, body)
				_ = model.groups
			}
			if index.isMultiple(of: 4) {
				await saves.measure { #expect(await model.flushPendingSaves()) }
			}
		}

		#expect(model.noteCount == 1_000)
		#expect(keystrokes.percentile(0.95) < 8, "keystroke p95 \(keystrokes.percentile(0.95)) ms")
		#expect(saves.percentile(0.95) < 100, "save p95 \(saves.percentile(0.95)) ms")
	}
}
