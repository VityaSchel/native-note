import NativeNoteKit
import SwiftUI

struct NoteListView: View {
	let groups: [NoteGroup]
	let now: Date
	@Binding var selection: UUID?
	@Binding var search: String
	let delete: (UUID) -> Void

	@FocusState private var focused: Bool

	var emptyState: (title: String, systemImage: String)? {
		guard groups.isEmpty else { return nil }
		return search.isEmpty ? ("No notes", "note.text") : ("No matches", "magnifyingglass")
	}

	static func separatorsHidden(for note: Note, in group: NoteGroup) -> VerticalEdge.Set {
		var hidden: VerticalEdge.Set = []
		if note.id == group.notes.first?.id { hidden.insert(.top) }
		if note.id == group.notes.last?.id { hidden.insert(.bottom) }
		return hidden
	}

	var body: some View {
		List(selection: Binding(get: { selection }, set: { chosen in
			selection = chosen
			focused = true
		})) {
			ForEach(groups) { group in
				Section(group.title) {
					ForEach(group.notes) { note in
						// Containing the row dodges a macOS previews trap on custom views used directly as List rows.
						// https://developer.apple.com/forums/thread/803429
						ZStack(alignment: .leading) { NoteRow(note: note, now: now) }
							.listRowInsets(EdgeInsets(top: 0, leading: 18.5, bottom: 0, trailing: 15.5))
							.listRowSeparator(.hidden, edges: Self.separatorsHidden(for: note, in: group))
							.tag(note.id)
					}
				}
			}
		}
		.listStyle(.inset)
		// SwiftUI sizes the first row added to an empty list at the default height and never measures it again.
		.id(groups.isEmpty)
		.focused($focused)
		.onDeleteCommand(perform: selection.map { id in { delete(id) } })
		.contextMenu(forSelectionType: UUID.self) { ids in
			if let id = ids.first {
				Button("Delete") { delete(id) }
			}
		}
		.searchable(text: $search, placement: .automatic, prompt: "Search")
		.overlay {
			if let emptyState {
				ContentUnavailableView(emptyState.title, systemImage: emptyState.systemImage)
			}
		}
	}
}

#if DEBUG
	#Preview("Note list") {
		@Previewable @State var selection: UUID? = NoteGroup.samples[0].notes[0].id
		@Previewable @State var search = ""

		NavigationStack {
			NoteListView(groups: NoteGroup.samples, now: Note.sampleNow, selection: $selection, search: $search) { _ in }
		}
		.frame(width: 300, height: 460)
	}

	#Preview("Note list, empty") {
		NavigationStack {
			NoteListView(groups: [], now: Note.sampleNow, selection: .constant(nil), search: .constant("")) { _ in }
		}
		.frame(width: 300, height: 460)
	}
#endif
