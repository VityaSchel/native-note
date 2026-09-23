import Foundation
import Observation

@MainActor @Observable final class AppModel {
	enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
	}

	enum Failure: Equatable {
		case wrongPassword
		case unexpected(String)
	}

	private(set) var phase: Phase = .loading
	private(set) var notes: [Note] = []
	private(set) var failure: Failure?
	var selection: UUID?
	var search = ""

	var groups: [NoteGroup] {
		NoteGrouping.groups(for: visibleNotes, now: .now)
	}

	var selectedNote: Note? {
		selection.flatMap { id in notes.first { $0.id == id } }
	}

	private let directory: URL
	private let database: URL
	private let scheduler: SaveScheduler
	private var store: NoteStore?
	private var matches: [UUID]?

	init(directory: URL = AppLock.directory, debounce: Duration = .milliseconds(300)) {
		self.directory = directory
		database = directory.appending(path: "notes.db")
		scheduler = SaveScheduler(debounce: debounce)
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

	func lock() {
		store = nil
		notes = []
		selection = nil
		phase = .locked
	}

	func createNote() async {
		let now = Date()
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: true)
		await write { try await $0.save(note) }
		selection = notes.contains { $0.id == note.id } ? note.id : nil
	}

	func edit(_ body: String) {
		guard var edited = selectedNote, edited.body != body else { return }
		edited.body = body
		edited.updatedAt = Date()
		edited.dirty = true
		replaceInMemory(edited)

		let pending = edited
		scheduler.schedule { [weak self] in await self?.write { try await $0.save(pending) } }
	}

	func deleteSelected() async {
		guard let id = selection else { return }
		selection = nil
		await write { try await $0.markDeleted(id: id, at: Date()) }
	}

	func runSearch() async {
		guard let store else { return }
		let text = search
		guard !text.isEmpty else {
			matches = nil
			return
		}
		matches = try? await store.search(text).map(\.id)
	}

	private var visibleNotes: [Note] {
		guard let matches else { return notes }
		let ranking = Dictionary(uniqueKeysWithValues: matches.enumerated().map { ($0.element, $0.offset) })
		return notes.filter { ranking[$0.id] != nil }.sorted { ranking[$0.id]! < ranking[$1.id]! }
	}

	private func discardSelectionIfMissing() {
		guard let selected = selection, !notes.contains(where: { $0.id == selected }) else { return }
		selection = nil
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
			discardSelectionIfMissing()
			phase = .unlocked
		} catch {
			failure = Self.failure(from: error)
		}
	}

	private func write(_ body: @escaping (NoteStore) async throws -> Void) async {
		guard let store else { return }
		do {
			try await body(store)
			notes = try await store.liveNotes()
			discardSelectionIfMissing()
		} catch {
			failure = Self.failure(from: error)
		}
	}

	func dismissFailure() {
		failure = nil
	}

	private static func failure(from error: Error) -> Failure {
		switch error {
		case Unlock.Failure.wrongPassword, SQLiteError.wrongKey:
			.wrongPassword
		case Unlock.Failure.neverSetUp:
			.unexpected("No unlock parameters were found beside the notes database.")
		case SQLiteError.checkpointBlocked:
			.unexpected("The notes database is busy. Try again.")
		case let SQLiteError.cannotOpen(_, message):
			.unexpected("The notes database could not be opened. \(message)")
		case let SQLiteError.cannotExecute(_, message, _):
			.unexpected(message)
		case let SQLiteError.keyMustBe32Bytes(count):
			.unexpected("The unlock key was \(count) bytes rather than 32.")
		default:
			.unexpected(String(describing: error))
		}
	}
}

#if DEBUG
	extension AppModel {
		static func previewing(_ notes: [Note]) -> AppModel {
			let model = AppModel(directory: URL(fileURLWithPath: "/dev/null"))
			model.notes = notes
			model.phase = .unlocked
			model.selection = notes.first?.id
			return model
		}
	}
#endif
