import NativeNoteKit
import SwiftUI

struct NoteRow: View {
	static let titleFont = Font(NSFont.preferredFont(forTextStyle: .headline).withSingleStoreyA as CTFont)
	static let detailFont = Font(NSFont.preferredFont(forTextStyle: .callout).withSingleStoreyA as CTFont)

	let note: Note
	let now: Date

	private var preview: String {
		note.body
			.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			.dropFirst()
			.joined()
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			.joined(separator: " ")
	}

	var displayTitle: String {
		note.title.isEmpty ? "New note" : note.title
	}

	var displayPreview: String {
		preview.isEmpty ? "No additional text" : preview
	}

	var dateLabel: String {
		NoteGrouping.dateLabel(for: note.updated, now: now)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(displayTitle)
				.font(Self.titleFont)
				.lineLimit(1)

			HStack(spacing: 8) {
				Text(dateLabel)
					.font(Self.detailFont)
				Text(displayPreview)
					.font(Self.detailFont)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
		}
		.padding(.top, 12)
		.padding(.bottom, 13)
	}
}

#if DEBUG
	#Preview("Row") {
		List {
			ZStack(alignment: .leading) { NoteRow(note: .sample(1, "Shopping\nquartz, bread, and a new kettle", minutesAgo: 5), now: Note.sampleNow) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(3, "", minutesAgo: 200), now: Note.sampleNow) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(4, "Reading list\nRFC 9106", minutesAgo: 1_500), now: Note.sampleNow) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(5, "Trip plan\nferry at 07:20", minutesAgo: 5_000), now: Note.sampleNow) }
			ZStack(alignment: .leading) { NoteRow(note: .sample(6, "Trip plan\nferry at 07:20", minutesAgo: 40_000), now: Note.sampleNow) }
		}
		.frame(width: 300)
	}
#endif
