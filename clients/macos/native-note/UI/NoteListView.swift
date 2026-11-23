import NativeNoteKit
import SwiftUI

struct NoteListView: View {
	let groups: [NoteGroup]
	let now: Date
	@Binding var selection: UUID?
	@Binding var search: String
	var focusesSearch = Binding.constant(false)
	var yieldsFocus = false
	let delete: (UUID) -> Void

	@Environment(\.calendar) private var calendar
	@FocusState private var focused: Bool
	@FocusState private var searching: Bool

	enum EmptyState {
		case noNotes
		case noResults
	}

	var emptyState: EmptyState? {
		guard groups.isEmpty else { return nil }
		return search.isEmpty ? .noNotes : .noResults
	}

	static func separatorsHidden(for note: Note, in group: NoteGroup) -> VerticalEdge.Set {
		var hidden: VerticalEdge.Set = []
		if note.id == group.notes.first?.id { hidden.insert(.top) }
		if note.id == group.notes.last?.id { hidden.insert(.bottom) }
		return hidden
	}

	private static func previewSafe(_ row: NoteRow) -> some View {
		ZStack(alignment: .leading) { row }
	}

	private var remeasuresFirstRow: Bool {
		groups.isEmpty
	}

	var body: some View {
		List(selection: Binding(get: { selection }, set: { chosen in
			selection = chosen
			focused = true
		})) {
			ForEach(groups) { group in
				Section(group.title) {
					ForEach(group.notes) { note in
						Self.previewSafe(NoteRow(note: note, now: now, calendar: calendar))
							.listRowInsets(EdgeInsets(top: 0, leading: 18.5, bottom: 0, trailing: 15.5))
							.listRowSeparator(.hidden, edges: Self.separatorsHidden(for: note, in: group))
							.tag(note.id)
					}
				}
			}
		}
		.listStyle(.inset)
		.id(remeasuresFirstRow)
		.focused($focused)
		.onDeleteCommand(perform: selection.map { id in { delete(id) } })
		.contextMenu(forSelectionType: UUID.self) { ids in
			if let id = ids.first {
				Button("Delete") { delete(id) }
			}
		}
		.searchable(text: $search, placement: .automatic, prompt: "Search")
		.searchFocused($searching)
		.onChange(of: focusesSearch.wrappedValue, initial: true) { _, wanted in
			guard wanted else { return }
			focusesSearch.wrappedValue = false
			Task { searching = true }
		}
		.overlay {
			switch emptyState {
			case .noNotes: ContentUnavailableView("No Notes", systemImage: "note.text")
			case .noResults: ContentUnavailableView.search
			case nil: EmptyView()
			}
		}
		.onChange(of: remeasuresFirstRow) { _, rebuiltEmpty in
			if rebuiltEmpty, focused { Task { focused = true } }
		}
		.onAppear {
			Task { if !searching, !yieldsFocus { focused = true } }
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
