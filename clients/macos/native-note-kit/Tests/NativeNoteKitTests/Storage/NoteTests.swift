import Foundation
import Testing

@testable import NativeNoteKit

struct NoteTests {
	@Test func exposesTheFirstLineAsTheTitle() {
		#expect(sampleNote().title == "first line")
		#expect(sampleNote(body: "  padded  \nrest").title == "padded")
		#expect(sampleNote(body: "single").title == "single")
	}
}
