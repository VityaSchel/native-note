import NativeNoteKit
import SwiftUI

struct NoteRow: View {
	let note: Note

	private var preview: String {
		note.body
			.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			.dropFirst()
			.joined()
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var displayTitle: String {
		note.title.isEmpty ? "New note" : note.title
	}

	var displayPreview: String {
		preview.isEmpty ? "No additional text" : preview
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(displayTitle)
				.font(.body.weight(.semibold))
				.lineLimit(1)

			HStack(spacing: 6) {
				Text(note.updatedAt, format: .dateTime.hour().minute())
					.font(.callout)
				Text(displayPreview)
					.font(.callout)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(.vertical, 2)
	}
}

#if DEBUG
	#Preview("Row") {
		List {
			ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5)) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200)) }
		}
		.frame(width: 300)
	}
#endif
