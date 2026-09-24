import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct AppModelTests {
	private func workspace() -> URL {
		URL.temporaryDirectory.appending(path: UUID().uuidString)
	}

	@Test func walksSetUpEditLockAndUnlock() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast })

		model.start()
		#expect(model.phase == .needsSetup)

		await model.setUp(password: "correct horse")
		#expect(model.phase == .unlocked)
		#expect(model.notes.isEmpty)

		await model.createNote()
		#expect(model.notes.count == 1)
		let id = try #require(model.selection)

		model.edit(id, "Shopping\nquartz and bread")
		#expect(model.selectedNote?.title == "Shopping")

		await model.lock()
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

		let model = AppModel(directory: directory, makeParameters: { .fast })
		model.start()

		#expect(model.phase == .locked)
	}

	@Test func searchFiltersTheGroupsAndClearingItRestoresThem() async throws {
		let directory = workspace()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast })
		await model.setUp(password: "correct horse")

		for body in ["Shopping\nquartz and bread", "Standup\nshipped storage"] {
			await model.createNote()
			model.edit(try #require(model.selection), body)
		}
		await model.flushPendingSaves()

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
		let model = AppModel(directory: directory, makeParameters: { .fast })
		await model.setUp(password: "correct horse")
		await model.createNote()

		await model.deleteSelected()

		#expect(model.notes.isEmpty)
		#expect(model.selection == nil)
	}
}
