import Foundation
import Observation

@Observable public final class AppModel {
	public enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
	}

	private struct FailingSave {
		let note: Note
		let reason: String
	}

	public private(set) var phase: Phase = .loading
	private(set) var notes: [Note] = []
	public private(set) var failure: Failure?
	public private(set) var conflicts: [NoteConflict] = []
	public private(set) var isImporting = false
	public private(set) var canUnlockWithBiometrics = false
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

	public var noteCount: Int {
		notes.count
	}

	private let directory: URL
	private let scheduler: SaveScheduler
	private let makeParameters: @Sendable () throws -> UnlockParameters
	private let searchNotes: @Sendable (NoteStore, String) async throws -> [Note]
	private let exportParameters: Argon2.Parameters
	private let keyStore: any UnlockKeyStore
	private var unlockedKey: Data?
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
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.makeParameters,
		searchNotes: @escaping @Sendable (NoteStore, String) async throws -> [Note] = AppModel.search,
		exportParameters: Argon2.Parameters = Argon2.floor,
		keyStore: (any UnlockKeyStore)? = nil
	) {
		self.directory = directory
		self.scheduler = scheduler
		self.makeParameters = makeParameters
		self.searchNotes = searchNotes
		self.exportParameters = exportParameters
		self.keyStore = keyStore ?? KeychainUnlockKeyStore(directory: directory)
	}

	public func start() {
		phase = AppLock.parameterFiles(in: directory).isEmpty ? .needsSetup : .locked
		refreshBiometricUnlock()
	}

	func setUp(password: String) async {
		await openLibrary {
			let unlocked = try await Unlock.setUp(password: password, in: self.directory, makeParameters: self.makeParameters)
			try? self.keyStore.delete()
			return unlocked
		}
	}

	func unlock(password: String) async {
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
		conflicts = []
		unlockedKey = nil
		refreshBiometricUnlock()
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
		await delete(id)
	}

	public func delete(_ id: UUID) async {
		if selection == id { selection = nil }
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
			let found = try await searchNotes(store, text).map(\.id)
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

	public func dismissFailure() {
		failure = nil
	}

	public func eraseLibrary() async {
		guard phase == .locked else { return }
		let retired = retiring
		retiring = nil
		await retired?.close()
		await scheduler.discardAll()
		failingSaves = [:]
		failure = nil
		search = ""
		matches = nil
		try? keyStore.delete()
		do {
			try AppLock.erase(in: directory)
		} catch {
			report(error)
		}
		start()
	}

	public var isBiometricUnlockEnabled: Bool {
		keyStore.hasKey()
	}

	@discardableResult
	public func enableBiometricUnlock() async -> Bool {
		guard phase == .unlocked, let unlockedKey, keyStore.isAvailable else { return false }
		do {
			try keyStore.save(unlockedKey)
			return true
		} catch {
			failure = .unexpected("Touch ID unlock could not be turned on. \((error as? KeychainFailure)?.message ?? error.localizedDescription)")
			return false
		}
	}

	public func disableBiometricUnlock() {
		do {
			try keyStore.delete()
		} catch {
			failure = .unexpected("Touch ID unlock could not be turned off. \((error as? KeychainFailure)?.message ?? error.localizedDescription)")
		}
		refreshBiometricUnlock()
	}

	public func unlockWithBiometrics() async {
		let key: Data?
		do {
			key = try await keyStore.load(reason: "unlock your notes")
		} catch {
			forgetStoredKey(explaining: "Touch ID could not read the unlock key. Unlock with your password.")
			return
		}
		guard let key, phase == .locked else { return }
		if let error = await openLibrary({ try await Unlock.open(key: key, in: self.directory) }),
			case Unlock.Failure.storedKeyRejected = error
		{
			forgetStoredKey(explaining: Failure.reason(for: error))
		}
	}

	private func forgetStoredKey(explaining message: String) {
		try? keyStore.delete()
		refreshBiometricUnlock()
		failure = .unexpected(message)
	}

	private func refreshBiometricUnlock() {
		canUnlockWithBiometrics = phase == .locked && keyStore.isAvailable && keyStore.hasKey()
	}

	public static func isEncryptedExport(at url: URL) -> Bool {
		let head = try? FileHandle(forReadingFrom: url).read(upToCount: 64)
		return head.map(ExportEnvelope.isEncrypted) ?? false
	}

	@discardableResult
	public func exportLibrary(to url: URL, passphrase: String?) async -> Bool {
		let notes = notes
		let parameters = exportParameters
		do {
			try await BlockingWork.run {
				let archive = try LibraryArchive.archive(notes)
				let file = try passphrase.map { try ExportEnvelope.seal(archive, passphrase: $0, parameters: parameters) } ?? archive
				try file.write(to: url, options: .atomic)
			}
			return true
		} catch {
			report(error)
			return false
		}
	}

	@discardableResult
	public func importLibrary(from url: URL, passphrase: String?) async -> ImportSummary? {
		guard let store, !isImporting, conflicts.isEmpty else { return nil }
		isImporting = true
		defer { isImporting = false }
		let incoming: [Note]
		do {
			incoming = try await BlockingWork.run {
				guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= LibraryArchive.maximumSize else {
					throw LibraryArchive.Failure.tooLarge
				}
				let file = try Data(contentsOf: url, options: .mappedIfSafe)
				return try LibraryArchive.notes(in: passphrase.map { try ExportEnvelope.open(file, passphrase: $0) } ?? file)
			}
		} catch {
			report(error)
			return nil
		}

		var summary = ImportSummary()
		func stopped(at index: Int) -> ImportSummary {
			summary.notImported = incoming.count - index
			return summary
		}
		for (index, theirs) in incoming.enumerated() {
			guard store === self.store else { return stopped(at: index) }
			if let mine = notes.first(where: { $0.id == theirs.id }) {
				if mine.body == theirs.body {
					summary.unchanged += 1
				} else {
					conflicts.append(NoteConflict(mine: mine, theirs: theirs))
					summary.conflicting += 1
				}
				continue
			}
			let deletedHere: Bool
			do {
				deletedHere = try await store.note(id: theirs.id) != nil
			} catch {
				guard store === self.store else { return stopped(at: index) }
				report(error)
				return nil
			}
			if deletedHere {
				summary.deletedHere += 1
				continue
			}
			guard await write({ try await $0.save(theirs) }) else {
				guard store === self.store else { return stopped(at: index) }
				return nil
			}
			summary.added += 1
			if store === self.store { notes.append(theirs) }
		}
		return summary
	}

	public func resolve(_ conflict: NoteConflict, _ choice: NoteConflict.Choice) async {
		conflicts.removeAll { $0.id == conflict.id }
		guard choice == .keepTheirs, var kept = notes.first(where: { $0.id == conflict.id }) else { return }
		await scheduler.discard(kept.id)
		kept.body = conflict.theirs.body
		kept.updatedAt = Date()
		kept.dirty = true
		replaceInMemory(kept)
		guard let store else { return }
		scheduleSave(kept, to: store)
		_ = await scheduler.flush(kept.id)
	}

	nonisolated private static func search(_ store: NoteStore, for text: String) async throws -> [Note] {
		try await store.search(text)
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

	@discardableResult
	private func openLibrary(_ open: @escaping () async throws -> Unlock.Unlocked) async -> Error? {
		failure = nil
		do {
			let unlocked = try await open()
			let opened = unlocked.store
			let loaded = try await opened.liveNotes()
			store = opened
			unlockedKey = unlocked.key
			let carried = failingSaves.values.map(\.note)
			notes = loaded
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
			canUnlockWithBiometrics = false
			return nil
		} catch {
			if case Unlock.Failure.alreadySetUp = error { phase = .locked }
			failure = Failure(error)
			return error
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
