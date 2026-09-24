import NativeNoteKit
import SwiftUI

struct NoteListView: View {
	let groups: [NoteGroup]
	@Binding var selection: UUID?
	@Binding var search: String

	var emptyState: (title: String, systemImage: String)? {
		guard groups.isEmpty else { return nil }
		return search.isEmpty ? ("No notes", "note.text") : ("No matches", "magnifyingglass")
	}

	var body: some View {
		List(selection: $selection) {
			ForEach(groups) { group in
				Section(group.title) {
					ForEach(group.notes) { note in
						// Containing the row dodges a macOS previews trap on custom views used directly as List rows.
						// https://developer.apple.com/forums/thread/803429
						ZStack(alignment: .leading) { NoteRow(note: note) }
							.tag(note.id)
					}
				}
			}
		}
		.listStyle(.inset)
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
			NoteListView(groups: NoteGroup.samples, selection: $selection, search: $search)
		}
		.frame(width: 300, height: 460)
	}

	#Preview("Note list, empty") {
		NavigationStack {
			NoteListView(groups: [], selection: .constant(nil), search: .constant(""))
		}
		.frame(width: 300, height: 460)
	}
#endif
