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

	@Test func aFirstSetupShowsTheSyncStepInTheWindowAndNotNowOpensTheLibrary() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, calibrate: { UnlockParameters.fast.argon }, keyStore: FakeKeyStore())
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { model.phase == .needsSetup }

		await model.submit(password: workspacePassword)
		await offscreen.pump { offscreen.accessibilityElements(.staticText).contains { $0.value == "Sync Your Notes" } }

		#expect(offscreen.sheet == nil)
		#expect(offscreen.window.title != "All Notes")
		try #require(offscreen.accessibilityElements(.button).first { $0.label == "Not Now" }).press()
		await offscreen.pump { offscreen.window.title == "All Notes" }

		#expect(!model.offersSyncSetup)
		#expect(offscreen.window.title == "All Notes")
	}

	@Test func anAccessibilityClientReadsTheLibrary() {
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()

		let elements = offscreen.attributeTree()
		offscreen.pump(for: 0.3)

		for button in ["Delete", "New Note", "Lock", "Search"] {
			#expect(elements.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.spoken == button }, "\(button)")
		}
		#expect(elements.contains { $0.role == "AXHeading" && $0.spoken == "August" })
		let rows = elements.filter { $0.role == NSAccessibility.Role.staticText.rawValue && $0.spoken.contains(", ") }
		#expect(rows.count == 5)
		#expect(rows.first?.spoken.hasPrefix("Shopping, ") == true)
		#expect(rows.first?.spoken.hasSuffix(", quartz, bread, and a new kettle") == true)
	}

	@Test func newNotePutsTheInsertionPointInTheNewNote() async throws {
		let (model, directory, offscreen) = try await library(["kayak"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let list = try #require(offscreen.views(of: NSTableView.self).first)
		try #require(offscreen.window.makeFirstResponder(list))

		await model.createNote()
		await offscreen.pump { model.focusesEditor == nil }

		let editor = try #require(offscreen.window.firstResponder as? NSTextView)
		#expect(editor.isEditable && editor.string.isEmpty)
		#expect(model.focusesEditor == nil)
	}

	@Test func searchNotesFocusesTheSearchField() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["kayak"])
		let exchange = LibraryExchange(model: model)
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()

		exchange.focusSearch(in: offscreen.window)
		await offscreen.pump { (offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField }

		#expect((offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField)
	}

	@Test func lockingTakesCopiedRecoveryWordsOffThePasteboard() async throws {
		let pasteboard = NSPasteboard(name: .init("dev.hloth.nativenote.tests.\(UUID().uuidString)"))
		defer { pasteboard.releaseGlobally() }
		let clipboard = RecoveryClipboard(pasteboard, sleep: { _ in try await Task.sleep(for: .seconds(600)) })
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model), clipboard: clipboard), width: 980, height: 560)
		defer { offscreen.close() }
		clipboard.copy(["abandon", "ability"])

		await model.lock()
		await offscreen.pump { pasteboard.string(forType: .string) == nil }

		#expect(pasteboard.string(forType: .string) == nil)
	}

	@Test func unlockingAnExistingLibraryOffersNothing() async throws {
		let (_, directory, offscreen) = try await library(["kayak"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		offscreen.pump()

		#expect(offscreen.sheet == nil)
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

		#expect(offscreen.window.title == "All Notes")
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

	@Test func undoBringsADeletedNoteBackAndRedoDeletesItAgain() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe trip"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let deleted = try #require(model.selectedNote)
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump { model.notes.count == 1 }
		let undo = try #require(offscreen.window.undoManager)
		#expect(undo.undoActionName == "Delete Note")

		undo.undo()

		let restored = try #require(model.notes.first { $0.body == deleted.body })
		#expect(restored.id != deleted.id)
		#expect(restored.createdAt == deleted.createdAt && restored.updatedAt == deleted.updatedAt)
		#expect(model.selection == restored.id)
		#expect(await model.flushPendingSaves())
		#expect(try await observer(of: directory).liveNotes().contains { $0.body == deleted.body })

		undo.redo()
		await offscreen.pump { model.notes.count == 1 }
		#expect(!model.notes.contains { $0.body == deleted.body })
	}

	@Test func undoAndRedoStepThroughTwoDeletes() async throws {
		let (model, directory, offscreen) = try await library(["first", "second", "third"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		let undo = try #require(offscreen.window.undoManager)
		// Offscreen, AppKit never closes the group it opens per event, so each delete gets its own as a key press would.
		undo.groupsByEvent = false
		for remaining in [2, 1] {
			model.selection = model.notes.first?.id
			try #require(offscreen.window.makeFirstResponder(list))
			offscreen.pump()
			undo.beginUndoGrouping()
			#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
			undo.endUndoGrouping()
			await offscreen.pump { model.notes.count == remaining }
		}

		undo.undo()
		undo.undo()
		#expect(model.notes.count == 3)
		undo.redo()
		await offscreen.pump { model.notes.count == 2 }
		#expect(undo.canRedo)
		undo.redo()
		await offscreen.pump { model.notes.count == 1 }

		#expect(model.notes.count == 1)
		#expect(undo.canUndo && !undo.canRedo)
		#expect(await model.flushPendingSaves())
		#expect(try await observer(of: directory).liveNotes().count == 1)
	}

	@Test func lockingClearsUndoDelete() async throws {
		let (model, directory, offscreen) = try await library(["kayak", "canoe trip"])
		defer { try? FileManager.default.removeItem(at: directory) }
		defer { offscreen.close() }
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		let undo = try #require(offscreen.window.undoManager)
		#expect(undo.canUndo)

		await model.lock()
		await offscreen.pump { !undo.canUndo }

		#expect(!undo.canUndo)
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

	@Test func returningToTheLockedAppUnlocksWithATouch() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["kayak"])
		try await turnOnTouchID(model)
		keys.forgetReads()
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
		defer { offscreen.close() }
		let sensor = Sensor()
		sensor.watch(keys, in: offscreen.window)

		model.appResignedActive()
		await model.lock()
		offscreen.pump(for: 0.2)
		#expect(model.phase == .locked)
		#expect(keys.contexts.isEmpty)

		model.appBecameActive()
		await offscreen.pump { sensor.isWaiting }
		sensor.touch()
		await offscreen.pump { model.phase == .unlocked }

		#expect(model.phase == .unlocked)
		#expect(keys.reasons == ["unlock your notes"])
		#expect(sensor.readsThroughAGlyphInTheWindow == [true])
		#expect(model.notes.map(\.body) == ["kayak"])
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
