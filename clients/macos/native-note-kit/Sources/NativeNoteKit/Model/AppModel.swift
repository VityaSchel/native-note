import Foundation
import Observation

@Observable public final class AppModel {
	public enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
	}

	public enum Failure: Equatable {
		case wrongPassword
		case unsaved(String)
		case unexpected(String)
	}

	public private(set) var phase: Phase = .loading
	private(set) var notes: [Note] = []
	public private(set) var failure: Failure?
	public var selection: UUID? {
		didSet {
			guard let previous = oldValue, previous != selection else { return }
			Task { await scheduler.flush(previous) }
		}
	}
	public var search = ""

	public var unsavedReason: String? {
		failingSaves.values.first?.reason
	}

	public var groups: [NoteGroup] {
		NoteGrouping.groups(for: visibleNotes, now: .now)
	}

	public var selectedNote: Note? {
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
	private var retiring: NoteStore?
	private var failingSaves: [UUID: FailingSave] = [:]
	private var searchFailing = false
	private var matches: [UUID]?

	public convenience init() {
		self.init(directory: AppLock.directory)
	}

	init(directory: URL, scheduler: SaveScheduler = SaveScheduler()) {
		self.directory = directory
		database = directory.appending(path: "notes.db")
		self.scheduler = scheduler
	}

	public func start() {
		phase = AppLock.candidates(in: directory).isEmpty ? .needsSetup : .locked
	}

	public func setUp(password: String) async {
		await attach { try await Unlock.setUp(password: password, database: self.database, in: self.directory) }
	}

	public func unlock(password: String) async {
		await attach { try await Unlock.open(password: password, database: self.database, in: self.directory) }
	}

	public func lock() async {
		let closing = store
		phase = .locked
		selection = nil
		notes = []
		store = nil
		failure = nil
		failingSaves = [:]
		searchFailing = false
		await scheduler.flushAll()
		guard let closing else { return }
		if unsavedReason == nil { await closing.close() } else { retiring = closing }
	}

	@discardableResult
	public func flushPendingSaves() async -> Bool {
		await scheduler.flushAll()
	}

	public func createNote() async {
		let now = Date()
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: true)
		guard await write({ try await $0.save(note) }) else { return }
		notes.insert(note, at: 0)
		selection = note.id
	}

	public func edit(_ id: UUID, _ body: String) {
		guard var edited = notes.first(where: { $0.id == id }), edited.body != body else { return }
		edited.body = body
		edited.updatedAt = Date()
		edited.dirty = true
		replaceInMemory(edited)

		guard let store else { return }
		scheduleSave(edited, to: store)
	}

	public func deleteSelected() async {
		guard let id = selection else { return }
		selection = nil
		guard await write({ try await $0.markDeleted(id: id, at: Date()) }) else { return }
		await scheduler.discard(id)
		notes.removeAll { $0.id == id }
	}

	public func runSearch() async {
		guard let store else { return }
		let text = search
		guard !text.isEmpty else {
			matches = nil
			searchFailing = false
			return
		}
		do {
			matches = try await store.search(text).map(\.id)
			searchFailing = false
		} catch {
			guard store === self.store else { return }
			matches = []
			if !searchFailing { report(error) }
			searchFailing = true
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
				await self?.saveLanded(note.id, in: store)
				return true
			} catch {
				await self?.saveFailed(note, to: store, after: error)
				return false
			}
		}
	}

	private func saveLanded(_ id: UUID, in landed: NoteStore) async {
		failingSaves[id] = nil
		guard failingSaves.isEmpty else { return }
		if case .unsaved = failure { failure = nil }
		guard landed === retiring else { return }
		retiring = nil
		await landed.close()
	}

	private func saveFailed(_ failed: Note, to store: NoteStore, after error: Error) {
		let reason = Self.reason(for: error)
		if failingSaves.isEmpty { failure = .unsaved(reason) }
		let latest = Self.newer(notes.first { $0.id == failed.id }, failed)
		failingSaves[failed.id] = FailingSave(note: latest, reason: reason)
		scheduleSave(latest, to: self.store ?? store)
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
			let carried = failingSaves.values.map(\.note)
			notes = try await opened.liveNotes()
			for note in carried {
				guard let index = notes.firstIndex(where: { $0.id == note.id }) else { continue }
				notes[index] = Self.newer(note, notes[index])
				if failingSaves[note.id] != nil { scheduleSave(notes[index], to: opened) }
			}
			if let old = retiring {
				retiring = nil
				await old.close()
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
			if store === self.store { report(error) }
			return false
		}
	}

	private func report(_ error: Error) {
		failure = Self.failure(from: error)
	}

	public func dismissFailure() {
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
		case SQLiteError.closed:
			"The notes database is closed."
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
		public static var previewingFirstRun: AppModel {
			AppModel(directory: URL(fileURLWithPath: "/dev/null"))
		}

		public static func previewing(_ notes: [Note], failure: Failure? = nil) -> AppModel {
			let model = AppModel(directory: URL(fileURLWithPath: "/dev/null"))
			model.notes = notes
			model.phase = .unlocked
			model.selection = notes.first?.id
			model.failure = failure
			return model
		}
	}
#endif
