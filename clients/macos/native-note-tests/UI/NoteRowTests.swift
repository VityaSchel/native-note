import NativeNoteKit
import SwiftUI
import Testing

@testable import NativeNote

@MainActor
struct NoteRowTests {
	@Test func theRowShowsTheTitleAndTheTextAfterIt() {
		let row = NoteRow(note: .sample(1, "Title\n  first body line\nsecond", minutesAgo: 0), now: Note.sampleNow)

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "first body line\nsecond")
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

	@Test func theTitleIsBoldAndLargerThanTheText() {
		let context = EnvironmentValues().fontResolutionContext
		let title = NoteRow.titleFont.resolve(in: context)

		#expect(title.weight == Font.body.weight(.bold).resolve(in: context).weight)
		#expect(title.pointSize > Font.body.resolve(in: context).pointSize)
	}

	@Test func aCrlfBodyShowsItsSecondLine() {
		let row = NoteRow(note: .sample(1, "Title\r\nbody", minutesAgo: 0), now: Note.sampleNow)

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "body")
	}
}
