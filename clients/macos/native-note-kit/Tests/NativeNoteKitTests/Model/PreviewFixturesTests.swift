import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct PreviewFixturesTests {
	@Test func sampleGroupsCoverTheRowStatesTheCanvasShouldShow() {
		let notes = NoteGroup.samples.flatMap(\.notes)

		#expect(NoteGroup.samples.map(\.title) == ["Today", "Yesterday", "July"])
		#expect(notes.contains { $0.title.isEmpty })
		#expect(notes.contains { $0.body.contains("\n") })
		#expect(Set(notes.map(\.id)).count == notes.count)
		#expect(Set(NoteGroup.samples.map(\.id)).count == NoteGroup.samples.count)
	}

	@Test func previewingModelIsUnlockedWithoutTouchingTheDisk() {
		let notes = NoteGroup.samples.flatMap(\.notes)

		let model = AppModel.previewing(notes)

		#expect(model.phase == .unlocked)
		#expect(model.notes.count == notes.count)
		#expect(model.selection == notes.first?.id)
		#expect(model.groups.map(\.id) == NoteGrouping.groups(for: notes, now: .now).map(\.id))
	}

	@Test func groupsAreIdenticalAcrossRepeatedReads() {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
		let first = model.groups

		for _ in 0 ..< 200 {
			#expect(model.groups == first)
		}
	}

	@Test func previewingModelIgnoresCreateNote() async {
		let notes = NoteGroup.samples.flatMap(\.notes)
		let model = AppModel.previewing(notes)

		await model.createNote()

		#expect(model.notes == notes)
		#expect(model.selection == notes.first?.id)
		#expect(model.failure == nil)
	}

	@Test func previewEditsStayInMemory() throws {
		let model = AppModel.previewing(NoteGroup.samples.flatMap(\.notes))
		let id = try #require(model.selection)

		model.edit(id, "changed in the canvas")

		#expect(model.selectedNote?.body == "changed in the canvas")
	}
}
