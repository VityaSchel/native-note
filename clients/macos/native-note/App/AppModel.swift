import Foundation
import Observation

@Observable final class AppModel {
	enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
	}

	enum Failure: Equatable {
		case wrongPassword
		case unsaved(String)
		case unexpected(String)
	}

	private(set) var phase: Phase = .loading
	private(set) var notes: [Note] = []
	private(set) var failure: Failure?
	var selection: UUID? {
		didSet {
			guard let previous = oldValue, previous != selection else { return }
			Task { await scheduler.flush(previous) }
		}
	}
	var search = ""

	var unsavedReason: String? {
		failingSaves.values.first?.reason
	}

	var groups: [NoteGroup] {
		NoteGrouping.groups(for: visibleNotes, now: .now)
	}

	var selectedNote: Note? {
		selection.flatMap { id in notes.first { $0.id == id } }
	}

	private let directory: URL
	private let database: URL
	private struct FailingSave {
		let note: Note
		let reason: String
	}

	private let scheduler: SaveScheduler
	private var store: NoteStore?
	private var failingSaves: [UUID: FailingSave] = [:]
	private var matches: [UUID]?

	init(directory: URL = AppLock.directory, scheduler: SaveScheduler = SaveScheduler()) {
		self.directory = directory
		database = directory.appending(path: "notes.db")
		self.scheduler = scheduler
	}

	func start() {
		phase = AppLock.candidates(in: directory).isEmpty ? .needsSetup : .locked
	}

	func setUp(password: String) async {
		await attach { try await Unlock.setUp(password: password, database: self.database, in: self.directory) }
	}

	func unlock(password: String) async {
		await attach { try await Unlock.open(password: password, database: self.database, in: self.directory) }
	}

	func lock() async {
		phase = .locked
		selection = nil
		notes = []
		store = nil
		failure = nil
		failingSaves = [:]
		await scheduler.flushAll()
	}

	@discardableResult
	func flushPendingSaves() async -> Bool {
		await scheduler.flushAll()
	}

	func createNote() async {
		let now = Date()
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: true)
		guard await write({ try await $0.save(note) }) else { return }
		notes.insert(note, at: 0)
		selection = note.id
	}

	func edit(_ id: UUID, _ body: String) {
		guard var edited = notes.first(where: { $0.id == id }), edited.body != body else { return }
		edited.body = body
		edited.updatedAt = Date()
		edited.dirty = true
		replaceInMemory(edited)

		guard let store else { return }
		scheduleSave(edited, to: store)
	}

	func deleteSelected() async {
		guard let id = selection else { return }
		selection = nil
		guard await write({ try await $0.markDeleted(id: id, at: Date()) }) else { return }
		await scheduler.discard(id)
		notes.removeAll { $0.id == id }
	}

	func runSearch() async {
		guard let store else { return }
		let text = search
		guard !text.isEmpty else {
			matches = nil
			return
		}
		do {
			matches = try await store.search(text).map(\.id)
		} catch {
			matches = []
			report(error)
		}
	}

	private var visibleNotes: [Note] {
		guard let matches else { return notes }
		let ranking = Dictionary(uniqueKeysWithValues: matches.enumerated().map { ($0.element, $0.offset) })
		return notes.filter { ranking[$0.id] != nil }.sorted { ranking[$0.id]! < ranking[$1.id]! }
	}

	private func scheduleSave(_ note: Note, to store: NoteStore) {
		scheduler.schedule(note.id) { [weak self] in
			do {
				try await store.save(note)
				await self?.saveLanded(note.id)
				return true
			} catch {
				await self?.saveFailed(note, to: store, after: error)
				return false
			}
		}
	}

	private func saveLanded(_ id: UUID) {
		failingSaves[id] = nil
	}

	private func saveFailed(_ failed: Note, to store: NoteStore, after error: Error) {
		let reason = Self.reason(for: error)
		if failingSaves.isEmpty { failure = .unsaved(reason) }
		let latest = Self.newer(notes.first { $0.id == failed.id }, failed)
		failingSaves[failed.id] = FailingSave(note: latest, reason: reason)
		scheduleSave(latest, to: store)
	}

	private static func newer(_ held: Note?, _ other: Note) -> Note {
		guard let held, held.updatedAt > other.updatedAt else { return other }
		return held
	}

	private func replaceInMemory(_ note: Note) {
		guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
		notes[index] = note
	}

	private func attach(_ open: @escaping () async throws -> NoteStore) async {
		failure = nil
		do {
			let opened = try await open()
			store = opened
			notes = try await opened.liveNotes()
			for failing in failingSaves.values {
				guard let index = notes.firstIndex(where: { $0.id == failing.note.id }) else { continue }
				notes[index] = Self.newer(failing.note, notes[index])
				scheduleSave(notes[index], to: opened)
			}
			if let unsavedReason { failure = .unsaved(unsavedReason) }
			phase = .unlocked
		} catch {
			failure = Self.failure(from: error)
		}
	}

	private func write(_ body: (NoteStore) async throws -> Void) async -> Bool {
		guard let store else { return false }
		do {
			try await body(store)
			return true
		} catch {
			report(error)
			return false
		}
	}

	private func report(_ error: Error) {
		failure = Self.failure(from: error)
	}

	func dismissFailure() {
		failure = nil
	}

	private static func failure(from error: Error) -> Failure {
		switch error {
		case Unlock.Failure.wrongPassword, SQLiteError.wrongKey:
			.wrongPassword
		default:
			.unexpected(reason(for: error))
		}
	}

	private static func reason(for error: Error) -> String {
		switch error {
		case Unlock.Failure.neverSetUp:
			"No unlock parameters were found beside the notes database."
		case SQLiteError.checkpointBlocked:
			"The notes database is busy. Try again."
		case SQLiteError.newerSchema:
			"The notes database was written by a newer version of Native Note. Update the app to open it."
		case let SQLiteError.cannotOpen(_, message):
			"The notes database could not be opened. \(message)"
		case let SQLiteError.cannotExecute(_, message, _):
			message
		case let SQLiteError.keyMustBe32Bytes(count):
			"The unlock key was \(count) bytes rather than 32."
		default:
			String(describing: error)
		}
	}
}

#if DEBUG
	extension AppModel {
		static func previewing(_ notes: [Note], failure: Failure? = nil) -> AppModel {
			let model = AppModel(directory: URL(fileURLWithPath: "/dev/null"))
			model.notes = notes
			model.phase = .unlocked
			model.selection = notes.first?.id
			model.failure = failure
			return model
		}
	}
#endif
