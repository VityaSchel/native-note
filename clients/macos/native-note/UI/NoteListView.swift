import NativeNoteKit
import SwiftUI

struct NoteListView: View {
	let groups: [NoteGroup]
	@Binding var selection: UUID?
	@Binding var search: String

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
			if groups.isEmpty {
				ContentUnavailableView(
					search.isEmpty ? "No notes" : "No matches",
					systemImage: search.isEmpty ? "note.text" : "magnifyingglass"
				)
			}
		}
	}
}

struct NoteRow: View {
	let note: Note

	private var preview: String {
		note.body
			.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
			.dropFirst()
			.joined()
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(note.title.isEmpty ? "New note" : note.title)
				.font(.body.weight(.semibold))
				.lineLimit(1)

			HStack(spacing: 6) {
				Text(note.updatedAt, format: .dateTime.hour().minute())
					.font(.callout)
				Text(preview.isEmpty ? "No additional text" : preview)
					.font(.callout)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(.vertical, 2)
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

	#Preview("Row") {
		List {
			ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5)) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200)) }
		}
		.frame(width: 300)
	}
#endif
