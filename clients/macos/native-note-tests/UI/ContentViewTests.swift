import AppKit
import SwiftUI
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor @Suite(.takesFocus, .scratch, .timeLimit(.minutes(10)))
struct ContentViewTests {
	private let alarm = Alarm()

	private func window(showing model: AppModel) -> OffscreenWindow<ContentView> {
		OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
	}

	private func typePasswords(_ password: String, in offscreen: OffscreenWindow<ContentView>) throws {
		for placeholder in ["Password", "Confirm Password"] {
			try offscreen.type(password, into: placeholder)
		}
		offscreen.window.firstResponder?.insertNewline(nil)
	}

	@Test func exportingOpensTheSavePanelOnlyOnceTheSheetHasClosedAndWritesTheChosenFile() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["Shopping"])
		let exchange = LibraryExchange(model: model)
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		let file = directory.appending(path: "chosen.nnexport")
		var panels: [(name: String, sheetClosed: Bool)] = []
		exchange.presentPanel = { panel, chosen in
			panels.append((panel.nameFieldStringValue, offscreen.sheet == nil))
			chosen(file)
		}

		exchange.isExporting = true
		await offscreen.pump { offscreen.sheet != nil }
		let sheet = try #require(offscreen.sheet)
		let fields = offscreen.sheetViews(of: NSSecureTextField.self)
		try #require(fields.count == 2)
		for field in fields {
			try #require(sheet.makeFirstResponder(field))
			try #require(field.currentEditor()).insertText("correct staple")
			offscreen.pump()
		}
		try #require(offscreen.sheetAccessibilityElements(.button).first { $0.label == "Export…" }).press()
		await offscreen.pump(turns: 4_000) { FileManager.default.fileExists(atPath: file.path) }

		#expect(panels.map(\.name) == ["Native Note.nnexport"])
		#expect(panels.map(\.sheetClosed) == [true])
		#expect(AppModel.isEncryptedExport(at: file))
		#expect(exchange.isIdle)
	}

	@Test func aFirstLaunchWalksWelcomePasswordTouchIDAndSyncInTheWindowThenOpensTheLibrary() async throws {
		let directory = temporaryDirectory()
		let model = AppModel.testing(in: directory)
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { model.phase == .needsSetup }

		try await offscreen.pressOnceShown("Next")
		try typePasswords(workspacePassword, in: offscreen)
		await offscreen.pump { offscreen.accessibilityElements().contains { $0.label == "Unlock with Touch ID?" || $0.value == "Unlock with Touch ID?" } }
		#expect(model.phase == .unlocked && model.isOnboarding)
		#expect(offscreen.window.title != "All Notes")

		try await offscreen.pressOnceShown("Skip")
		await offscreen.pump { offscreen.accessibilityElements().contains { $0.label == "Sync Your Notes" || $0.value == "Sync Your Notes" } }
		#expect(offscreen.sheet == nil)
		try await offscreen.pressOnceShown("Not Now")
		await offscreen.pump { offscreen.window.title == "All Notes" }

		#expect(!model.isOnboarding)
		#expect(offscreen.window.title == "All Notes")
	}

	@Test func aMissedTouchWhileOnboardingIsReadOutAndTryingAgainSaysToTouchAgain() async throws {
		let keys = FakeKeyStore()
		let model = AppModel.testing(in: temporaryDirectory(), keyStore: keys)
		let spoken = Spoken()
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model), announce: { spoken.heard.append($0) }), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { model.phase == .needsSetup }
		model.appBecameActive()
		try await offscreen.pressOnceShown("Next")
		try typePasswords(workspacePassword, in: offscreen)
		await offscreen.pump { offscreen.button("Set Up Touch ID") != nil }
		keys.reply(with: .miss)

		try offscreen.press("Set Up Touch ID")
		await offscreen.pump(turns: 4_000) { offscreen.tryAgainButton != nil }

		#expect(model.touchID == .needsClick(after: .miss))
		#expect(spoken.heard == [OnboardingView.touchIDLine, "Touch ID didn't match."])

		keys.reply(with: .key)
		try #require(offscreen.tryAgainButton).press()
		await offscreen.pump(turns: 4_000) { offscreen.button("Not Now") != nil }

		#expect(model.isBiometricUnlockEnabled)
		#expect(spoken.heard == [OnboardingView.touchIDLine, "Touch ID didn't match.", OnboardingView.touchIDLine])
	}

	@Test func aRelaunchAfterThePasswordStepUnlocksStraightIntoTheLibrary() async throws {
		let directory = temporaryDirectory()
		let first = AppModel.testing(in: directory)
		first.start()
		await first.submit(password: workspacePassword)
		try #require(first.isOnboarding)
		await first.lock()

		let relaunched = AppModel.testing(in: directory)
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: relaunched)), width: 980, height: 560)
		defer { offscreen.close() }
		await offscreen.pump { relaunched.phase == .locked }
		#expect(!offscreen.accessibilityElements().contains { $0.label == "Welcome to Native Note" || $0.value == "Welcome to Native Note" })
		await relaunched.submit(password: workspacePassword)
		await offscreen.pump { offscreen.window.title == "All Notes" }

		#expect(!relaunched.isOnboarding)
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
		#expect(elements.contains { $0.role == NSAccessibility.Role.textArea.rawValue && $0.description == NoteEditor.spokenName })
	}

	@Test func voiceControlNamesATitledNoteByItsTitleAndLeavesAnUntitledOneItsFullName() throws {
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()

		let rows = offscreen.attributeTree().filter { $0.role == NSAccessibility.Role.staticText.rawValue && $0.spoken.contains(", ") }
		try #require(rows.count == 5)

		#expect(rows.map(\.inputLabels) == [["Shopping"], ["Standup notes"], [], ["Reading list"], ["Trip plan"]])
		#expect(rows.first?.spoken.hasPrefix("Shopping, ") == true)
		#expect(rows[2].spoken.hasPrefix("New Note, "))
	}

	@Test func voiceOverReadsTheOpenNotesDateLineInWordsBetweenTheListAndTheNote() throws {
		let notes = NoteGroup.samples.flatMap(\.notes)
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: .previewing(notes))), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()

		let elements = offscreen.attributeTree()
		let spoken = NoteGrouping.spokenEditorDateLine(for: notes[0].updated)

		let lastRow = try #require(elements.lastIndex { $0.role == NSAccessibility.Role.staticText.rawValue && $0.spoken.hasPrefix("Trip plan, ") })
		let dateLine = try #require(elements.firstIndex { $0.role == NSAccessibility.Role.staticText.rawValue && $0.spoken == spoken })
		let editor = try #require(elements.firstIndex { $0.role == NSAccessibility.Role.textArea.rawValue && $0.description == NoteEditor.spokenName })
		#expect(lastRow < dateLine)
		#expect(dateLine < editor)
		#expect(elements.count { $0.spoken == spoken } == 1)
		#expect(!elements.contains { $0.spoken.contains(NoteGrouping.editorDateLine(for: notes[0].updated)) })
	}

	@Test func returnClosesTheImportSummary() async throws {
		let exchange = LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }

		exchange.lastImport = ImportSummary(added: 3)
		await offscreen.pump { offscreen.sheet != nil }

		let sheet = try #require(offscreen.sheet)
		let ok = try #require(offscreen.sheetViews(of: NSButton.self).first { $0.title == "OK" })

		#expect(ok.keyEquivalent == "\r")
		#expect(try offscreen.pressReturn(in: sheet))
	}

	@Test func returnClosesTheFailureAlertAsItDoesTheImportSummary() async throws {
		let exchange = LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes), failure: .unsaved("disk I/O error")))
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { offscreen.sheet != nil }

		let sheet = try #require(offscreen.sheet)
		let ok = try #require(offscreen.sheetViews(of: NSButton.self).first { $0.title == "OK" })

		#expect(ok.keyEquivalent == "\r")
		#expect(try offscreen.pressReturn(in: sheet))
	}

	@Test func theToolbarButtonsKeepTheirGapsToSearchAsTheWindowWidens() throws {
		func edges(width: CGFloat) throws -> [CGFloat] {
			let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes)))), width: width, height: 420)
			defer { offscreen.close() }
			offscreen.host.sceneBridgingOptions = .all
			offscreen.window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
			offscreen.window.setContentSize(NSSize(width: width, height: 420))
			offscreen.pump(for: 0.5)
			let items = offscreen.window.toolbar?.items ?? []
			return try ["New Note", "Delete", "Lock", "Search"].map { label in
				let item = try #require(items.first { $0.label == label }, "\(label)")
				return try #require(Self.frame(of: item), "\(label)").minX
			}
		}

		let narrow = try edges(width: 900)
		let wide = try edges(width: 1400)

		#expect(zip(narrow, wide).map { $1 - $0 } == [500, 500, 500, 500])
	}

	private static func frame(of item: NSToolbarItem) -> NSRect? {
		let viewer = class_getInstanceVariable(NSToolbarItem.self, "_itemViewer") != nil ? item.value(forKey: "_itemViewer") as? NSView : nil
		guard let view = item.view ?? viewer else { return nil }
		return view.convert(view.bounds, to: nil)
	}

	@Test func newNotePutsTheInsertionPointInTheNewNote() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak"])
		let offscreen = window(showing: model)
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
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kayak"])
		let exchange = LibraryExchange(model: model)
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()

		exchange.searchNotes()
		await offscreen.pump { (offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField }

		#expect((offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField)
	}

	@Test func unlockingAnExistingLibraryOffersNothing() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		offscreen.pump()

		#expect(offscreen.sheet == nil)
	}

	@Test func aSearchFiltersTheList() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }

		model.search = "kayak"
		await offscreen.pump { model.groups.flatMap(\.notes).count == 1 }

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak"])
	}

	@Test func typingInTheEditorEditsTheShownNote() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["Title"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { $0.string == "Title" })

		editor.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
		await offscreen.pump { model.selectedNote?.body != "Title" }

		#expect(model.selectedNote?.body == "Title typed")
		#expect(await model.flushPendingSaves())
	}

	private func pull(_ body: String, v: UInt32, over id: UUID, into model: AppModel) async throws {
		let content = Content.note(id: id, createdAt: 1, updatedAt: 2, body: body)
		let exchange = Exchange(changes: [PulledChange(content: content, v: v, writeId: NoteCipher.randomWriteId())], nextSeq: UInt64(v))
		_ = try await model.commit(.exchange(exchange), to: #require(model.store))
	}

	@Test func aKeyTypedBeforeTheEditorShowsAPullKeepsBothTexts() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["Title"])
		let id = try #require(model.selection)
		try await pull("Title", v: 1, over: id, into: model)
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { $0.string == "Title" })

		try await pull("from the other device", v: 2, over: id, into: model)
		try #require(editor.string == "Title", "the editor has not shown the pull yet")
		editor.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
		await model.flushPendingSaves()
		await offscreen.pump { model.selection != id }

		#expect(model.selectedNote?.body == "Title typed")
		#expect(Set(model.notes.map(\.body)) == ["Title typed", "from the other device"])
		#expect(await model.flushPendingSaves())
	}

	@Test func typingAfterAPullThatKeptTheTextStaysInTheNote() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["Title"])
		let id = try #require(model.selection)
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let editor = try #require(offscreen.views(of: NSTextView.self).first { $0.string == "Title" })

		try await pull("Title", v: 1, over: id, into: model)
		offscreen.pump()
		editor.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
		await model.flushPendingSaves()

		#expect(model.selection == id)
		#expect(model.notes.map(\.body) == ["Title typed"])
	}

	@Test func theToolbarNamesTheNotebookAndCountsItsNotes() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }

		#expect(offscreen.window.title == "All Notes")
		#expect(offscreen.window.subtitle == "2 notes")

		await model.deleteSelected()
		await offscreen.pump { offscreen.window.subtitle != "2 notes" }

		#expect(offscreen.window.subtitle == "1 note")
	}

	@Test func deleteInTheListDeletesTheSelectedNote() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe"])
		let offscreen = window(showing: model)
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
		let (model, directory) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe trip"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let deleted = try #require(model.selectedNote)
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		let undo = try #require(offscreen.window.undoManager)
		await offscreen.pump { model.notes.count == 1 && undo.canUndo }
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

	@Test func aDeleteOrARedoneDeleteThatFailsLeavesNothingToUndo() async throws {
		let (model, directory) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe trip"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let blocker = try await connection(to: directory)
		try await model.store?.failAtOnceWhenLocked()
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()
		let undo = try #require(offscreen.window.undoManager)
		undo.groupsByEvent = false

		try blocker.execute("BEGIN IMMEDIATE")
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump(turns: 4_000) { model.failure != nil }
		try blocker.execute("ROLLBACK")
		offscreen.pump(for: 0.05)

		try #require(model.failure != nil)
		#expect(model.notes.count == 2)
		#expect(!undo.canUndo)
		model.dismissFailure()

		try #require(offscreen.window.makeFirstResponder(list))
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump { model.notes.count == 1 && undo.canUndo }
		undo.undo()
		#expect(await model.flushPendingSaves())
		try #require(model.notes.count == 2 && undo.canRedo)

		try blocker.execute("BEGIN IMMEDIATE")
		undo.redo()
		await offscreen.pump(turns: 4_000) { model.failure != nil }
		try blocker.execute("ROLLBACK")
		offscreen.pump(for: 0.05)

		try #require(model.failure != nil)
		#expect(model.notes.count == 2)
		#expect(!undo.canUndo)
		model.dismissFailure()
	}

	@Test func undoAndRedoStepThroughTwoDeletes() async throws {
		let (model, directory) = try await Workspace(alarm: alarm).unlocked(holding: ["first", "second", "third"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		let undo = try #require(offscreen.window.undoManager)
		undo.groupsByEvent = false
		let offered = UndoSteps()
		NotificationCenter.default.addObserver(offered, selector: #selector(UndoSteps.closed), name: .NSUndoManagerDidCloseUndoGroup, object: undo)
		defer { NotificationCenter.default.removeObserver(offered) }
		for remaining in [2, 1] {
			model.selection = model.notes.first?.id
			try #require(offscreen.window.makeFirstResponder(list))
			offscreen.pump()
			#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
			await offscreen.pump { model.notes.count == remaining && offered.count == 3 - remaining }
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
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe trip"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let list = try #require(offscreen.views(of: NSTableView.self).first { $0.numberOfRows > 1 })
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		let undo = try #require(offscreen.window.undoManager)
		await offscreen.pump { undo.canUndo }
		#expect(undo.canUndo)

		await model.lock()
		await offscreen.pump { !undo.canUndo }

		#expect(!undo.canUndo)
	}

	@Test func deleteInTheEditorDeletesTextNotTheNote() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["Title"])
		let offscreen = window(showing: model)
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

	private func noteColumn(in offscreen: OffscreenWindow<ContentView>) -> NSTableView? {
		offscreen.views(of: NSTableView.self).max { offscreen.onScreen($0).minX < offscreen.onScreen($1).minX }
	}

	private func listHasFocus(in offscreen: OffscreenWindow<ContentView>) -> Bool {
		noteColumn(in: offscreen).map { offscreen.window.firstResponder === $0 } ?? false
	}

	@Test func unlockingWithThePasswordPutsKeyboardFocusInTheNoteListAndASearchKeepsItsField() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe"])
		await model.lock()
		let exchange = LibraryExchange(model: model)
		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560)
		defer { offscreen.close() }
		let field = try offscreen.field("Password")
		try offscreen.type(workspacePassword, into: field)

		field.currentEditor()?.insertNewline(nil)
		await offscreen.pump(turns: 20_000) { model.phase == .unlocked && listHasFocus(in: offscreen) }

		#expect(model.phase == .unlocked)
		#expect(listHasFocus(in: offscreen))
		#expect((noteColumn(in: offscreen)?.numberOfRows ?? 0) > model.notes.count)
		exchange.searchNotes()
		await offscreen.pump { (offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField }
		try #require(offscreen.window.firstResponder as? NSText).insertText("zzzz")
		await offscreen.pump { model.groups.isEmpty }
		offscreen.pump(for: 0.2)
		#expect((offscreen.window.firstResponder as? NSText)?.delegate is NSSearchField)
	}

	@Test func leavingTheLastOnboardingStepPutsKeyboardFocusInTheNoteList() async throws {
		let model = AppModel.testing(in: temporaryDirectory())
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560, catchesSheets: true)
		defer { offscreen.close() }
		await offscreen.pump { model.phase == .needsSetup }
		try await offscreen.pressOnceShown("Next")
		try typePasswords(workspacePassword, in: offscreen)
		await offscreen.pump { offscreen.button("Skip") != nil || offscreen.button("Not Now") != nil }
		if offscreen.button("Skip") != nil { try offscreen.press("Skip") }

		try await offscreen.pressOnceShown("Not Now")
		await offscreen.pump { offscreen.window.title == "All Notes" && listHasFocus(in: offscreen) }

		#expect(!model.isOnboarding)
		#expect(listHasFocus(in: offscreen))
	}

	@Test func deletingTheLastNoteInTheListKeepsKeyboardFocusThereUntilANewNoteTakesIt() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak"])
		let offscreen = window(showing: model)
		defer { offscreen.close() }
		let list = try #require(noteColumn(in: offscreen))
		try #require(offscreen.window.makeFirstResponder(list))
		offscreen.pump()

		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		await offscreen.pump { model.notes.isEmpty }
		await offscreen.pump { listHasFocus(in: offscreen) }

		#expect(model.notes.isEmpty)
		#expect(listHasFocus(in: offscreen))
		await model.createNote()
		await offscreen.pump { model.focusesEditor == nil }
		#expect((offscreen.window.firstResponder as? NSTextView)?.isFieldEditor == false)
	}

	@Test func theFirstNoteInAnEmptyLibraryGetsAFullRow() async throws {
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: [])
		let offscreen = window(showing: model)
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
		let (model, _) = try await Workspace(alarm: alarm).unlocked(holding: ["kayak", "canoe"])
		let offscreen = window(showing: model)
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
		let (model, _) = try await unlockedModel { [alarm] directory in
			AppModel.testing(in: directory, scheduler: alarm.scheduler, keyStore: keys)
		}
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

	@Test func theWindowLeavesAWayToOpenItAgainOnceClosed() {
		let exchange = LibraryExchange(model: .previewing([]))
		#expect(exchange.showWindow == nil)

		let offscreen = OffscreenWindow(ContentView(exchange: exchange), width: 980, height: 560)
		defer { offscreen.close() }

		#expect(exchange.showWindow != nil)
	}

	@Test func closingTheWindowSavesAtOnce() async throws {
		let (model, directory) = try await Workspace(alarm: alarm).unlocked(holding: ["Title"])
		let offscreen = window(showing: model)
		let id = try #require(model.selection)
		let disk = try await observer(of: directory)

		model.edit(id, "typed then closed")
		offscreen.close()
		try await settle { try await disk.note(id: id)?.body == "typed then closed" }

		#expect(try await disk.note(id: id)?.body == "typed then closed")
	}
}

@MainActor private final class UndoSteps: NSObject {
	private(set) var count = 0

	@objc func closed() {
		count += 1
	}
}
