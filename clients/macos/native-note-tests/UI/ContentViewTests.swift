import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct ContentViewTests {
	private let alarm = Alarm()

	private func library(_ bodies: [String]) async throws -> (AppModel, URL, OffscreenWindow<ContentView>) {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: bodies)
		return (model, directory, OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560))
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
		#expect(await model.flushPendingSaves())
	}

	@Test func theToolbarNamesTheNotebookAndCountsItsNotes() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }

		#expect(offscreen.window.title == "All notes")
		#expect(offscreen.window.subtitle == "2 notes")

		await model.deleteSelected()
		await offscreen.pump { offscreen.window.subtitle != "2 notes" }

		#expect(offscreen.window.subtitle == "1 note")
	}

	@Test func deleteInTheListDeletesTheSelectedNote() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let selected = try #require(model.selection)
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()

		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump { model.notes.count == 1 }

		#expect(!model.notes.contains { $0.id == selected })
		#expect(model.notes.count == 1)
	}

	@Test func deleteInTheEditorDeletesTextNotTheNote() async throws {
		let (model, directory, offscreen) = try await library(["Title"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { $0.string == "Title" })
		try #require(offscreen.window.makeFirstResponder(editor))
		editor.setSelectedRange(NSRange(location: 0, length: 5))

		#expect(editor.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump { model.selectedNote?.body != "Title" }

		#expect(model.notes.count == 1)
		#expect(model.selectedNote?.body == "")
		#expect(await model.flushPendingSaves())
	}

	private func noteList(in offscreen: OffscreenWindow<ContentView>) throws -> NSTableView {
		try #require(offscreen.views(of: NSTableView.self).max { $0.numberOfRows < $1.numberOfRows })
	}

	@Test func theFirstNoteInAnEmptyLibraryGetsAFullRow() async throws {
		let (model, directory, offscreen) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }

		await model.createNote()
		model.edit(try #require(model.selection), "test\n123\n123")
		await offscreen.pump { (try? noteList(in: offscreen).numberOfRows) == 2 }
		await model.createNote()
		model.edit(try #require(model.selection), "2t\ntesta")
		await offscreen.pump { (try? noteList(in: offscreen).numberOfRows) == 3 }

		let list = try noteList(in: offscreen)
		let row = NSHostingView(rootView: NoteRow(note: try #require(model.selectedNote), now: .now)).fittingSize.height
		#expect(list.rect(ofRow: 1).height >= row, "row 1 is \(list.rect(ofRow: 1).height) pt, a row needs \(row) pt")
		#expect(list.rect(ofRow: 2).height >= row, "row 2 is \(list.rect(ofRow: 2).height) pt, a row needs \(row) pt")
		#expect(await model.flushPendingSaves())
	}

	@Test func pickingANoteInTheListFocusesTheList() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { !$0.isFieldEditor && $0.isEditable })
		try #require(offscreen.window.makeFirstResponder(editor))
		let list = try noteList(in: offscreen)
		let other = try #require(model.groups.first?.notes.last?.id)

		list.selectRowIndexes(IndexSet(integer: list.numberOfRows - 1), byExtendingSelection: false)
		await offscreen.pump { model.selection == other && offscreen.window.firstResponder === list }

		#expect(model.selection == other)
		#expect(offscreen.window.firstResponder === list)
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
