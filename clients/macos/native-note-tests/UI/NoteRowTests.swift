import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
struct NoteRowTests {
	@Test func theRowShowsTheTitleAndTheTextAfterIt() {
		let row = NoteRow(note: .sample(1, "Title\n  first body line\nsecond", minutesAgo: 0))

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "first body line\nsecond")
	}

	@Test func anUntitledNoteIsCalledNewNote() {
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 0)).displayTitle == "New note")
		#expect(NoteRow(note: .sample(1, "  \nbody", minutesAgo: 0)).displayTitle == "New note")
	}

	@Test func aNoteWithNothingAfterTheTitleSaysSo() {
		#expect(NoteRow(note: .sample(1, "", minutesAgo: 0)).displayPreview == "No additional text")
		#expect(NoteRow(note: .sample(1, "Title only", minutesAgo: 0)).displayPreview == "No additional text")
		#expect(NoteRow(note: .sample(1, "Title\n \n", minutesAgo: 0)).displayPreview == "No additional text")
	}

	@Test func aCrlfBodyShowsItsSecondLine() {
		let row = NoteRow(note: .sample(1, "Title\r\nbody", minutesAgo: 0))

		#expect(row.displayTitle == "Title")
		#expect(row.displayPreview == "body")
	}
}
