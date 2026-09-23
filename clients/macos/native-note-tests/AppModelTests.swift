import Foundation
import Testing

@testable import NativeNote

@MainActor
struct AppModelTests {
	private func workspace() -> URL {
		URL.temporaryDirectory.appending(path: UUID().uuidString)
	}

	@Test func walksSetUpEditLockAndUnlock() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, debounce: .milliseconds(20))

		model.start()
		#expect(model.phase == .needsSetup)

		await model.setUp(password: "correct horse")
		#expect(model.phase == .unlocked)
		#expect(model.notes.isEmpty)

		await model.createNote()
		#expect(model.notes.count == 1)
		let id = try #require(model.selection)

		model.edit("Shopping\nquartz and bread")
		#expect(model.selectedNote?.title == "Shopping")
		try await Task.sleep(for: .milliseconds(250))

		model.lock()
		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty)

		await model.unlock(password: "wrong horse")
		#expect(model.phase == .locked)
		#expect(model.failure != nil)

		await model.unlock(password: "correct horse")
		#expect(model.phase == .unlocked)
		#expect(model.notes.map(\.id) == [id])
		#expect(model.notes.first?.body == "Shopping\nquartz and bread")
	}

	@Test func startsLockedWhenParametersAlreadyExist() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(
			UnlockParameters(localSalt: Data(repeating: 1, count: 16), argon: Argon2.floor, enclaveKey: nil),
			to: AppLock.current(in: directory)
		)

		let model = AppModel(directory: directory)
		model.start()

		#expect(model.phase == .locked)
	}

	@Test func searchFiltersTheGroupsAndClearingItRestoresThem() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, debounce: .milliseconds(20))
		await model.setUp(password: "correct horse")

		for body in ["Shopping\nquartz and bread", "Standup\nshipped storage"] {
			await model.createNote()
			model.edit(body)
			try await Task.sleep(for: .milliseconds(120))
		}

		model.search = "quartz"
		await model.runSearch()
		#expect(model.groups.flatMap(\.notes).map(\.title) == ["Shopping"])

		model.search = "don't"
		await model.runSearch()
		#expect(model.groups.isEmpty)

		model.search = ""
		await model.runSearch()
		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func deletingRemovesTheNoteFromTheList() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, debounce: .milliseconds(20))
		await model.setUp(password: "correct horse")
		await model.createNote()

		await model.deleteSelected()

		#expect(model.notes.isEmpty)
		#expect(model.selection == nil)
	}
}

@MainActor
struct PreviewFixtureTests {
	@Test func sampleGroupsCoverTheRowStatesTheCanvasShouldShow() {
		let notes = NoteGroup.samples.flatMap(\.notes)

		#expect(NoteGroup.samples.map(\.title) == ["Today", "Yesterday", "July"])
		#expect(notes.contains { $0.title.isEmpty })
		#expect(notes.contains { $0.body.contains("\n") })
		#expect(Set(notes.map(\.id)).count == notes.count)
	}

	@Test func previewingModelIsUnlockedWithoutTouchingTheDisk() {
		let notes = NoteGroup.samples.flatMap(\.notes)

		let model = AppModel.previewing(notes)

		#expect(model.phase == .unlocked)
		#expect(model.notes.count == notes.count)
		#expect(model.selection == notes.first?.id)
		#expect(model.groups.map(\.id) == NoteGrouping.groups(for: notes, now: .now).map(\.id))
	}
}
