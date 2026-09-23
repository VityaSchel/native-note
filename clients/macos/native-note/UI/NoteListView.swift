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
	extension Note {
		static func sample(_ number: Int, _ body: String, minutesAgo: Int) -> Note {
			let moment = Date(timeIntervalSince1970: 1_786_000_000 - Double(minutesAgo) * 60)
			let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
			return Note(id: id, body: body, createdAt: moment, updatedAt: moment)
		}
	}

	extension Note {
		func movedTo(_ moment: Date) -> Note {
			var moved = self
			moved.createdAt = moment
			moved.updatedAt = moment
			return moved
		}
	}

	extension NoteGroup {
		static let samples = [
			NoteGroup(
				title: "Today",
				notes: [
					.sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5),
					.sample(2, "Standup notes\nshipped the storage layer", minutesAgo: 90),
					.sample(3, "", minutesAgo: 200),
				]
			),
			NoteGroup(title: "Yesterday", notes: [.sample(4, "Reading list\nRFC 9106, then the SQLCipher design doc", minutesAgo: 1_500)]),
			NoteGroup(title: "July", notes: [.sample(5, "Trip plan\nferry at 07:20", minutesAgo: 40_000)]),
		]
	}

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
