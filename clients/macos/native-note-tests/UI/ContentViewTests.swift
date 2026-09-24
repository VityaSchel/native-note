import AppKit
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ContentViewTests {
	private let alarm = Alarm()

	private func library(_ bodies: [String]) async throws -> (AppModel, URL, OffscreenWindow<ContentView>) {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: bodies)
		return (model, directory, OffscreenWindow(ContentView(model: model), width: 980, height: 560))
	}

	@Test func aSearchFiltersTheList() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }

		model.search = "kayak"
		await offscreen.pump { model.groups.flatMap(\.notes).count == 1 }

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak"])
	}

	@Test func typingInTheEditorEditsTheShownNote() async throws {
		let (model, directory, offscreen) = try await library(["Title"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { $0.string == "Title" })

		editor.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
		await offscreen.pump { model.selectedNote?.body != "Title" }

		#expect(model.selectedNote?.body == "Title typed")
	}

	@Test func closingTheWindowSavesAtOnce() async throws {
		let (model, directory, offscreen) = try await library(["Title"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let id = try #require(model.selection)
		let disk = try await observer(of: directory)

		model.edit(id, "typed then closed")
		offscreen.close()
		try await settle { try await disk.note(id: id)?.body == "typed then closed" }

		#expect(try await disk.note(id: id)?.body == "typed then closed")
	}
}
