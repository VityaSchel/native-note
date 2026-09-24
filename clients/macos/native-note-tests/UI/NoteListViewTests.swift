import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct NoteListViewTests {
	@Test func anEmptyLibrarySaysThereAreNoNotes() {
		let list = NoteListView(groups: [], selection: .constant(nil), search: .constant(""))

		#expect(list.emptyState?.title == "No notes")
		#expect(list.emptyState?.systemImage == "note.text")
	}

	@Test func aSearchWithoutResultsSaysThereAreNoMatches() {
		let list = NoteListView(groups: [], selection: .constant(nil), search: .constant("kayak"))

		#expect(list.emptyState?.title == "No matches")
		#expect(list.emptyState?.systemImage == "magnifyingglass")
	}

	@Test func aListWithNotesShowsNoPlaceholder() {
		let list = NoteListView(groups: NoteGroup.samples, selection: .constant(nil), search: .constant("kayak"))

		#expect(list.emptyState == nil)
	}
}
