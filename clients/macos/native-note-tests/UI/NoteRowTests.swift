import AppKit
import CoreText
import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct NoteRowTests {
	@Test func theRowShowsTheTitleAndTheTextAfterIt() {
		let row = NoteRow(note: .sample(1, "Title\n  first body line\nsecond", minutesAgo: 0), now: Note.sampleNow)

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "first body line second")
	}

	@Test func eachLineBreakInThePreviewBecomesASpaceLikeAppleNotes() {
		#expect(NoteRow(note: .sample(1, "Title\n123\n123", minutesAgo: 0), now: Note.sampleNow).displayPreview == "123 123")
		#expect(NoteRow(note: .sample(1, "Title\na\n\n\nb", minutesAgo: 0), now: Note.sampleNow).displayPreview == "a   b")
	}

	@Test func anUntitledNoteIsCalledNewNote() {
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 0), now: Note.sampleNow).displayTitle == "New note")
		#expect(NoteRow(note: .sample(1, "  \nbody", minutesAgo: 0), now: Note.sampleNow).displayTitle == "New note")
	}

	@Test func aNoteWithNothingAfterTheTitleSaysSo() {
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 0), now: Note.sampleNow).displayPreview == "No additional text")
		#expect(NoteRow(note: .sample(1, "Title only", minutesAgo: 0), now: Note.sampleNow).displayPreview == "No additional text")
		#expect(NoteRow(note: .sample(1, "Title\n \n", minutesAgo: 0), now: Note.sampleNow).displayPreview == "No additional text")
	}

	@Test func theDateSaysHowLongAgoTheNoteChanged() {
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 1_500), now: Note.sampleNow).dateLabel == "Yesterday")
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 1_500), now: Note.sampleNow.addingTimeInterval(-86_400)).dateLabel != "Yesterday")
	}

	@Test func aLongPreviewShrinksBeforeTheDate() {
		let note = Note.sample(1, "Standup\nshipped the storage layer and the export format, then reviewed the plan", minutesAgo: 60 * 24 * 3)
		let row = NoteRow(note: note, now: Note.sampleNow)
		let height = NSHostingView(rootView: row.frame(width: 190)).fittingSize.height

		#expect(row.dateLabel.count > 5)
		#expect(height == 56, "a narrow row is \(height) pt tall")
	}

	@Test func theRowWritesASingleStoreyALikeAppleNotes() {
		let context = EnvironmentValues().fontResolutionContext

		for (font, plain) in [(NoteRow.titleFont, Font.headline), (NoteRow.detailFont, Font.callout)] {
			#expect(glyph(of: "a", in: font.resolve(in: context).ctFont) != glyph(of: "a", in: plain.resolve(in: context).ctFont))
			#expect(glyph(of: "b", in: font.resolve(in: context).ctFont) == glyph(of: "b", in: plain.resolve(in: context).ctFont))
		}
	}

	@Test func theFontsMatchAppleNotes() {
		let context = EnvironmentValues().fontResolutionContext
		let title = NoteRow.titleFont.resolve(in: context)
		let detail = NoteRow.detailFont.resolve(in: context)

		#expect(title.weight == Font.body.weight(.bold).resolve(in: context).weight)
		#expect(title.pointSize == 13)
		#expect(detail.weight == Font.body.resolve(in: context).weight)
		#expect(detail.pointSize == 12)
		#expect(!detail.isMonospaced)
	}

	@Test func aCrlfBodyShowsItsSecondLine() {
		let row = NoteRow(note: .sample(1, "Title\r\nbody", minutesAgo: 0), now: Note.sampleNow)

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "body")
	}
}

func glyph(of character: String, in font: CTFont) -> CGGlyph {
	let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [.font: font]))
	let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first
	var glyph = CGGlyph()
	if let run { CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph) }
	return glyph
}
