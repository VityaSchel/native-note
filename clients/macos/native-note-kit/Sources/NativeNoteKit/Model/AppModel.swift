import Foundation
import Observation

@Observable public final class AppModel {
	public enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
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
		guard let matches else { return NoteGrouping.groups(for: notes, now: .now) }
		let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
		let ranked = matches.compactMap { notesByID[$0] }
		return ranked.isEmpty ? [] : [NoteGroup(title: "Results", notes: ranked)]
	}

	public var selectedNote: Note? {
		selection.flatMap { id in notes.first { $0.id == id } }
	}

	private let directory: URL
	private struct FailingSave {
		let note: Note
		let reason: String
	}

	private let scheduler: SaveScheduler
	private let makeParameters: @Sendable () throws -> UnlockParameters
	private var store: NoteStore?
	private var retiring: NoteStore?
	private var failingSaves: [UUID: FailingSave] = [:]
	private var searchFailing = false
	private var matches: [UUID]?

	public convenience init() {
		self.init(directory: AppLock.directory)
	}

	init(
		directory: URL,
		scheduler: SaveScheduler = SaveScheduler(),
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.createParameters
	) {
		self.directory = directory
		self.scheduler = scheduler
		self.makeParameters = makeParameters
	}

	public func start() {
		phase = AppLock.candidates(in: directory).isEmpty ? .needsSetup : .locked
	}

	public func setUp(password: String) async {
		await openLibrary {
			try await Unlock.setUp(password: password, in: self.directory, parameters: self.makeParameters)
		}
	}

	public func unlock(password: String) async {
		await openLibrary { try await Unlock.open(password: password, in: self.directory) }
	}

	public func submit(password: String) async {
		if phase == .needsSetup {
			await setUp(password: password)
		} else {
			await unlock(password: password)
		}
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
			let found = try await store.search(text).map(\.id)
			guard text == search, store === self.store else { return }
			matches = found
			searchFailing = false
		} catch {
			guard text == search, store === self.store else { return }
			matches = []
			if !searchFailing { report(error) }
			searchFailing = true
		}
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
		let reason = Failure.reason(for: error)
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

	private func openLibrary(_ open: @escaping () async throws -> NoteStore) async {
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
			if !search.isEmpty { await runSearch() }
			phase = .unlocked
		} catch {
			failure = Failure(error)
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
		failure = Failure(error)
	}

	public func dismissFailure() {
		failure = nil
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
