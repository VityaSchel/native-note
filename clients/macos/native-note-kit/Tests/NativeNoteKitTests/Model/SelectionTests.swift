import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct SelectionTests {
	private let alarm = Alarm()

	private func order(_ model: AppModel) -> [UUID] {
		model.groups.flatMap(\.notes).map(\.id)
	}

	@Test func deletingTheSelectedNoteSelectsTheNextOneOrThePreviousWhenItWasLast() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
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
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["first", "second"])
		let shown = order(model)
		model.selection = shown[0]

		await model.delete(shown[1])

		#expect(model.selection == shown[0])
	}

	@Test func unlockingSelectsTheTopNoteAndNothingOfTheLastSelection() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["older", "newer"])
		model.selection = order(model).last

		await model.lock()
		#expect(model.selection == nil)
		await model.unlock(password: workspacePassword)

		#expect(model.selection == order(model).first)
		#expect(model.selectedNote?.body == "newer")
	}

	@Test func newNoteClearsTheSearchAndAsksTheEditorForFocus() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
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

	@Test(arguments: ["", " \n"]) func aNewNoteLeftEmptyIsGoneAfterLocking(typed: String) async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kept"])
		await model.createNote()
		let empty = try #require(model.selection)
		model.edit(empty, typed)

		await model.lock()
		await model.unlock(password: workspacePassword)

		#expect(model.notes.map(\.body) == ["kept"])
		#expect(try await observer(of: directory).note(id: empty) == nil)
	}

	@Test func aNewNoteLeftEmptyIsGoneAfterQuitting() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["kept"])
		await model.createNote()
		let empty = try #require(model.selection)

		await model.close()

		let relaunched = AppModel(directory: directory, keyStore: FakeKeyStore())
		relaunched.start()
		await relaunched.unlock(password: workspacePassword)
		#expect(relaunched.notes.map(\.body) == ["kept"])
		#expect(try await observer(of: directory).note(id: empty) == nil)
	}

	private func aNewNoteTypedInAndCleared(in model: AppModel) async throws -> (kept: UUID, cleared: Note) {
		try await fill(model, with: ["kept"])
		let kept = try #require(model.selection)
		await model.createNote()
		let cleared = try #require(model.selection)
		model.edit(cleared, " ")
		#expect(await model.flushPendingSaves())
		return (kept, try #require(try await model.store?.note(id: cleared)))
	}

	private func firstPushAccepted(of pushed: Note) throws -> Commit {
		let content = Content.note(id: pushed.id, createdAt: pushed.createdAt, updatedAt: pushed.updatedAt, body: pushed.body)
		let sent = SealedWrite(note: pushed, write: try NoteCipher(contentKey: sharedContentKey).seal(content, v: 1))
		return .exchange(Exchange(sent: [sent], results: [WriteResult(status: .accepted, v: 1)], nextSeq: 1))
	}

	@Test(arguments: [false, true])
	func aNewNoteLeftEmptyWhileItsFirstPushIsAcknowledgedStaysOffTheList(discardedBeforeTheListIsReconciled: Bool) async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		let store = try #require(model.store)
		let (kept, cleared) = try await aNewNoteTypedInAndCleared(in: model)
		let acknowledgement = try firstPushAccepted(of: cleared)
		let discarded = { try await store.note(id: cleared.id)?.deleted == true }

		let applied: Applied
		if discardedBeforeTheListIsReconciled {
			applied = try await store.commit(acknowledgement)
			model.selection = kept
			try await settle(until: discarded)
			await model.reconcile(applied, in: store)
		} else {
			let committing = Task { try await model.commit(acknowledgement, to: store) }
			model.selection = kept
			applied = try await committing.value
			try await settle(until: discarded)
		}

		try #require(applied.changed[cleared.id]?.deleted == false, "the acknowledgement reached the store before the discard")
		#expect(!model.notes.contains { $0.id == cleared.id })
		let left = try #require(try await store.note(id: cleared.id))
		#expect((left.body, left.deleted, left.dirty, left.v) == ("", true, true, 1))
	}

	@Test func aNewNoteLeftEmptyWhileAnotherMacsEditOfItArrivesKeepsThatEdit() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		let store = try #require(model.store)
		let (kept, cleared) = try await aNewNoteTypedInAndCleared(in: model)
		_ = try await model.commit(firstPushAccepted(of: cleared), to: store)
		let elsewhere = Content.note(id: cleared.id, createdAt: cleared.createdAt, updatedAt: cleared.updatedAt + 1, body: "typed on another Mac")
		let pull = Commit.exchange(Exchange(changes: [PulledChange(content: elsewhere, v: 2, writeId: NoteCipher.randomWriteId())], nextSeq: 2))

		let committing = Task { try await model.commit(pull, to: store) }
		model.selection = kept
		_ = try await committing.value
		await model.close()

		#expect(model.notes.first { $0.id == cleared.id }?.body == "typed on another Mac")
		let left = try #require(try await observer(of: directory).note(id: cleared.id))
		#expect((left.body, left.deleted, left.dirty, left.v) == ("typed on another Mac", false, false, 2))
	}

	@Test func aNewNoteWithTextSurvivesLocking() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		await model.createNote()
		model.edit(try #require(model.selection), "Groceries")

		await model.lock()
		await model.unlock(password: workspacePassword)

		#expect(model.notes.map(\.body) == ["Groceries"])
	}

	@Test func aNewNoteWithTextStaysWhenLeft() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
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
