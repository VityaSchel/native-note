import AppKit
import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
private final class Deletions {
	var ids: [UUID] = []
}

@MainActor
struct NoteListViewTests {
	private func offscreen(selection: UUID?, _ deletions: Deletions) -> OffscreenWindow<NavigationStack<NavigationPath, NoteListView>> {
		OffscreenWindow(
			NavigationStack {
				NoteListView(groups: NoteGroup.samples, selection: .constant(selection), search: .constant("")) { deletions.ids.append($0) }
			},
			width: 300,
			height: 460
		)
	}

	private func focusedList(in offscreen: OffscreenWindow<NavigationStack<NavigationPath, NoteListView>>) throws -> NSTableView {
		let table = try #require(offscreen.views(of: NSTableView.self).first)
		try #require(offscreen.window.makeFirstResponder(table))
		offscreen.pump()
		return table
	}

	private func pressBackspace(on list: NSTableView, in offscreen: OffscreenWindow<NavigationStack<NavigationPath, NoteListView>>) throws {
		let backspace = try #require(
			NSEvent.keyEvent(
				with: .keyDown,
				location: .zero,
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				characters: "\u{7F}",
				charactersIgnoringModifiers: "\u{7F}",
				isARepeat: false,
				keyCode: 51
			)
		)
		list.keyDown(with: backspace)
		offscreen.pump()
	}

	private func editMenuDeleteIsEnabled(from focused: NSResponder) -> Bool {
		let delete = #selector(NSText.delete(_:))
		var responder: NSResponder? = focused
		while let current = responder, !current.responds(to: delete) {
			responder = current.nextResponder
		}
		let item = NSMenuItem(title: "Delete", action: delete, keyEquivalent: "")
		return (responder as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? false
	}

	@Test func deleteRemovesTheSelectedNote() throws {
		let deletions = Deletions()
		let selected = NoteGroup.samples[0].notes[1].id
		let offscreen = offscreen(selection: selected, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)

		#expect(editMenuDeleteIsEnabled(from: list))
		#expect(list.tryToPerform(#selector(NSText.delete(_:)), with: nil))
		try pressBackspace(on: list, in: offscreen)

		#expect(deletions.ids == [selected, selected])
	}

	@Test func deleteIsOffWithNothingSelected() throws {
		let deletions = Deletions()
		let offscreen = offscreen(selection: nil, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)

		#expect(!editMenuDeleteIsEnabled(from: list))
		try pressBackspace(on: list, in: offscreen)

		#expect(deletions.ids.isEmpty)
	}

	@Test func rightClickingARowOffersToDeleteThatRow() throws {
		let deletions = Deletions()
		let offscreen = offscreen(selection: NoteGroup.samples[0].notes[0].id, deletions)
		defer { offscreen.close() }
		let list = try focusedList(in: offscreen)
		let row = list.rect(ofRow: list.numberOfRows - 1)
		let click = try #require(
			NSEvent.mouseEvent(
				with: .rightMouseDown,
				location: list.convert(NSPoint(x: row.midX, y: row.midY), to: nil),
				modifierFlags: [],
				timestamp: 0,
				windowNumber: offscreen.window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
		)
		let menu = try #require(list.menu(for: click))

		#expect(menu.items.map(\.title) == ["Delete"])
		menu.performActionForItem(at: 0)
		offscreen.pump()

		#expect(deletions.ids == [NoteGroup.samples[2].notes[0].id])
	}

	@Test func anEmptyLibrarySaysThereAreNoNotes() {
		let list = NoteListView(groups: [], selection: .constant(nil), search: .constant("")) { _ in }

		#expect(list.emptyState?.title == "No notes")
		#expect(list.emptyState?.systemImage == "note.text")
	}

	@Test func aSearchWithoutResultsSaysThereAreNoMatches() {
		let list = NoteListView(groups: [], selection: .constant(nil), search: .constant("kayak")) { _ in }

		#expect(list.emptyState?.title == "No matches")
		#expect(list.emptyState?.systemImage == "magnifyingglass")
	}

	@Test func aListWithNotesShowsNoPlaceholder() {
		let list = NoteListView(groups: NoteGroup.samples, selection: .constant(nil), search: .constant("kayak")) { _ in }

		#expect(list.emptyState == nil)
	}
}
