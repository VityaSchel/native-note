import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SelectionTests {
	private let alarm = Alarm()

	private func order(_ model: AppModel) -> [UUID] {
		model.groups.flatMap(\.notes).map(\.id)
	}

	@Test func deletingTheSelectedNoteSelectsTheNextOneOrThePreviousWhenItWasLast() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["first", "second", "third"])
		let shown = order(model)

		model.selection = shown[1]
		await model.delete(shown[1])
		#expect(model.selection == shown[2])

		model.selection = shown[2]
		await model.delete(shown[2])
		#expect(model.selection == shown[0])

		await model.delete(shown[0])
		#expect(model.selection == nil)
	}

	@Test func deletingAnotherNoteKeepsTheSelection() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["first", "second"])
		let shown = order(model)
		model.selection = shown[0]

		await model.delete(shown[1])

		#expect(model.selection == shown[0])
	}

	@Test func unlockingSelectsTheTopNoteAndNothingOfTheLastSelection() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["older", "newer"])
		model.selection = order(model).last

		await model.lock()
		#expect(model.selection == nil)
		await model.unlock(password: workspacePassword)

		#expect(model.selection == order(model).first)
		#expect(model.selectedNote?.body == "newer")
	}

	@Test func newNoteClearsTheSearchAndAsksTheEditorForFocus() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["kayak", "canoe"])
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.flatMap(\.notes).count == 1)

		await model.createNote()

		#expect(model.search.isEmpty)
		#expect(model.groups.flatMap(\.notes).count == 3)
		#expect(model.focusesEditor == model.selection)
		model.editorTookFocus()
		#expect(model.focusesEditor == nil)
	}

	@Test func aNewNoteLeftEmptyLeavesNoTrace() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["kept"])
		let kept = try #require(model.selection)
		await model.createNote()
		let empty = try #require(model.selection)
		model.edit(empty, "  ")

		model.selection = kept
		#expect(await model.flushPendingSaves())
		let disk = try await observer(of: directory)
		try await settle { try await disk.note(id: empty) == nil }

		#expect(!model.notes.contains { $0.id == empty })
		let left = try await disk.note(id: empty)
		#expect(left == nil)
	}

	@Test func aNewNoteWithTextStaysWhenLeft() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["kept"])
		let kept = try #require(model.selection)
		await model.createNote()
		let written = try #require(model.selection)
		model.edit(written, "Groceries")

		model.selection = kept
		#expect(await model.flushPendingSaves())

		#expect(model.notes.contains { $0.id == written })
		#expect(try await observer(of: directory).note(id: written)?.body == "Groceries")
	}

	@Test func aNewNoteSyncsOnlyOnceItHasText() async throws {
		let server = try SyncServer()
		let (model, _) = try await syncingModel(server, idle: .seconds(3600))
		_ = try await setUpSync(model, server)
		await model.createNote()
		let id = try #require(model.selection)
		await model.syncNow()
		#expect(try await storedNotes(server) == 0)

		model.edit(id, "Now it has text")
		await model.syncNow()

		#expect(try await storedNotes(server) == 1)
	}

	private func storedNotes(_ server: SyncServer) async throws -> Int {
		let connection = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		guard case let .sync(_, changes, _, _) = try await connection.send(.sync(since: 0, writes: [])) else { throw SyncError.protocolViolation }
		return changes.count
	}
}
