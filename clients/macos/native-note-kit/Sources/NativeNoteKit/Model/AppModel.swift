import CryptoKit
import Foundation
import LocalAuthenticationEmbeddedUI
import Observation

@Observable public final class AppModel {
	public enum Phase: Equatable {
		case loading
		case needsSetup
		case locked
		case unlocked
	}

	public enum Screen: Equatable {
		case loading
		case onboarding
		case locked
		case library
	}

	private struct FailingSave {
		let note: Note
		let reason: String
	}

	public private(set) var phase: Phase = .loading {
		didSet { biometricUnlock.libraryIsLocked = phase == .locked }
	}

	public private(set) var isOnboarding = false

	public var screen: Screen {
		switch phase {
		case .loading: .loading
		case .needsSetup: .onboarding
		case .locked: .locked
		case .unlocked: isOnboarding ? .onboarding : .library
		}
	}

	var notes: [Note] = []
	public private(set) var failure: Failure?
	public private(set) var isImporting = false
	public var selection: UUID? {
		didSet {
			guard let previous = oldValue, previous != selection else { return }
			let leftEmpty = emptyNewNote(previous)
			createdThisSession.remove(previous)
			guard let leftEmpty else {
				Task { await scheduler.flush(previous) }
				return
			}
			notes.removeAll { $0.id == previous }
			guard let store else { return }
			discards[previous] = Task {
				await discard(leftEmpty, from: store)
				discards[previous] = nil
			}
		}
	}
	public private(set) var focusesEditor: UUID?
	public var search = "" {
		didSet {
			guard search.isEmpty, !oldValue.isEmpty else { return }
			matches = nil
			searchFailing = false
		}
	}

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

	let sync: LibrarySync
	let biometricUnlock: BiometricUnlock
	let scheduler: SaveScheduler
	let directory: URL
	private let makeParameters: @Sendable () throws -> UnlockParameters
	private let calibrate: @Sendable () throws -> Argon2.Parameters
	private let searchNotes: @Sendable (NoteStore, String) async throws -> [Note]
	private let exportParameters: Argon2.Parameters
	private let keyStore: any UnlockKeyStore
	private var unlockParameters: UnlockParameters?
	private var passwordChange: Task<Failure?, Never>?
	private(set) var store: NoteStore?
	private var awayEvents = 0
	private var retiring: NoteStore?
	private var failingSaves: [UUID: FailingSave] = [:]
	private var searchFailing = false
	private var matches: [UUID]?
	private var keptForUndo: [UUID: Note] = [:]
	private var createdThisSession: Set<UUID> = []
	private var discards: [UUID: Task<Void, Never>] = [:]
	private var creations: [UUID: Task<Void, Never>] = [:]

	public convenience init() {
		self.init(directory: AppLock.directory)
	}

	public convenience init(libraryAt directory: URL) {
		self.init(directory: directory)
	}

	init(
		directory: URL,
		scheduler: SaveScheduler = SaveScheduler(),
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.makeParameters,
		calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { try Argon2.calibrateMemory() },
		searchNotes: @escaping @Sendable (NoteStore, String) async throws -> [Note] = AppModel.search,
		exportParameters: Argon2.Parameters = Argon2.floor,
		keyStore: (any UnlockKeyStore)? = nil,
		shakeTimer: @escaping SaveScheduler.Sleep = { try await Task.sleep(for: $0) },
		makeTransport: @escaping @Sendable (URL) -> any SyncTransport = { HTTPTransport(url: $0) },
		syncDelay: Duration = .seconds(30)
	) {
		self.directory = directory
		self.scheduler = scheduler
		self.makeParameters = makeParameters
		self.calibrate = calibrate
		self.searchNotes = searchNotes
		self.exportParameters = exportParameters
		let keyStore = keyStore ?? KeychainUnlockKeyStore(directory: directory)
		self.keyStore = keyStore
		biometricUnlock = BiometricUnlock(keyStore: keyStore, shakeTimer: shakeTimer)
		sync = LibrarySync(scheduler: scheduler, makeTransport: makeTransport, syncDelay: syncDelay)
		sync.library = self
	}

	public func start() {
		phase = AppLock.parameterFiles(in: directory).isEmpty ? .needsSetup : .locked
		biometricUnlock.reset()
	}

	func setUp(password: String) async {
		await openLibrary(onboarding: true) {
			let unlocked = try await Unlock.setUp(password: password, in: self.directory, makeParameters: self.makeParameters)
			try? self.keyStore.delete()
			return unlocked
		}
	}

	public func finishOnboarding() {
		isOnboarding = false
	}

	func unlock(password: String) async {
		guard !biometricUnlock.isOpening else { return }
		biometricUnlock.checkingPassword(true)
		let error = await openLibrary { try await Unlock.open(password: password, in: self.directory) }
		if let error, Failure(error) == .wrongPassword { biometricUnlock.startShake() }
		biometricUnlock.checkingPassword(false)
	}

	@discardableResult
	public func submit(password: String) async -> Failure? {
		if phase == .needsSetup {
			await setUp(password: password)
		} else {
			await unlock(password: password)
		}
		return failure
	}

	public func lock() async {
		let closing = store
		let changingPassword = passwordChange
		changingPassword?.cancel()
		cancelTurningOnTouchID()
		let syncing = sync.stop()
		phase = .locked
		selection = nil
		notes = []
		keptForUndo = [:]
		createdThisSession = []
		focusesEditor = nil
		isOnboarding = false
		store = nil
		failure = nil
		failingSaves = [:]
		searchFailing = false
		unlockParameters = nil
		biometricUnlock.reset()
		await scheduler.flushAll()
		await syncing?.value
		_ = await changingPassword?.value
		await finishCreations()
		await finishDiscards()
		guard let closing else { return }
		if unsavedReason == nil { await closing.close() } else { retiring = closing }
	}

	@discardableResult
	public func flushPendingSaves() async -> Bool {
		await scheduler.flushAll()
	}

	public func close() async {
		let changingPassword = passwordChange
		changingPassword?.cancel()
		cancelTurningOnTouchID()
		let syncing = sync.stop()
		await finishCreations()
		if let selection, emptyNewNote(selection) != nil { self.selection = nil }
		await scheduler.flushAll()
		await syncing?.value
		_ = await changingPassword?.value
		await finishDiscards()
		let open = [store, retiring].compactMap(\.self)
		store = nil
		retiring = nil
		for store in open { await store.close() }
	}

	public func createNote() async {
		guard let store else { return }
		let now = Date().epochMilliseconds
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: false)
		let creating = Task {
			await create(note, in: store)
			creations[note.id] = nil
		}
		creations[note.id] = creating
		await creating.value
	}

	private func create(_ note: Note, in store: NoteStore) async {
		guard await write("The new note could not be created.", { try await $0.save(note) }) else { return }
		guard store === self.store else { return await discard(note, from: store) }
		if !search.isEmpty { search = "" }
		notes.insert(note, at: 0)
		createdThisSession.insert(note.id)
		selection = note.id
		focusesEditor = note.id
	}

	public func editorTookFocus() {
		focusesEditor = nil
	}

	private func emptyNewNote(_ id: UUID) -> Note? {
		guard createdThisSession.contains(id), let note = notes.first(where: { $0.id == id }) else { return nil }
		return note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? note : nil
	}

	private func discard(_ note: Note, from store: NoteStore) async {
		await scheduler.discard(note.id)
		do {
			try await store.discardUnsynced(id: note.id, shownAt: note.v, at: Date().epochMilliseconds)
		} catch {
			if store === self.store { report(error, as: "The empty note could not be removed.") }
		}
	}

	private func finishCreations() async {
		while let creating = creations.values.first {
			await creating.value
		}
	}

	private func finishDiscards() async {
		while let discarding = discards.values.first {
			await discarding.value
		}
	}

	public func edit(_ id: UUID, _ body: String) {
		guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
		var edited = notes[index]
		edited.body = body
		edited.updatedAt = Date().epochMilliseconds
		edited.dirty = true
		notes[index] = edited

		guard let store else { return }
		scheduleSave(edited, to: store)
		sync.soon()
	}

	func deleteSelected() async {
		guard let id = selection else { return }
		await delete(id)
	}

	@discardableResult
	public func delete(_ id: UUID) async -> Bool {
		let order = groups.flatMap(\.notes).map(\.id)
		if selection == id, let index = order.firstIndex(of: id) {
			selection = order.indices.contains(index + 1) ? order[index + 1] : index > 0 ? order[index - 1] : nil
		} else if selection == id {
			selection = nil
		}
		let shown = notes.firstIndex { $0.id == id }.map { notes.remove(at: $0) }
		guard await write("The note could not be deleted.", { try await $0.markDeleted(id: id, at: Date().epochMilliseconds) }) else {
			keptForUndo[id] = nil
			if let shown, store != nil, !notes.contains(where: { $0.id == id }) { notes.append(shown) }
			return false
		}
		await scheduler.discard(id)
		notes.removeAll { $0.id == id }
		sync.soon()
		return true
	}

	public func keepForUndo(_ id: UUID) -> UUID? {
		guard let note = notes.first(where: { $0.id == id }) else { return nil }
		keptForUndo[id] = note
		return id
	}

	@discardableResult
	public func restore(_ kept: UUID) -> UUID? {
		guard let store, !notes.contains(where: { $0.id == kept }), let deleted = keptForUndo.removeValue(forKey: kept) else { return nil }
		let note = deleted.unsyncedCopy()
		notes.append(note)
		selection = note.id
		scheduleSave(note, to: store)
		if let rank = matches?.firstIndex(of: kept) {
			matches?[rank] = note.id
		} else if matches != nil {
			Task {
				await scheduler.flush(note.id)
				await runSearch()
			}
		}
		sync.soon()
		return note.id
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
			if !searchFailing { report(error, as: "Search could not run.") }
			searchFailing = true
		}
	}

	public func dismissFailure() {
		failure = nil
	}

	public func eraseLibrary() async {
		guard phase == .locked, !biometricUnlock.isOpening else { return }
		_ = await passwordChange?.value
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
			report(error, as: "The library could not be erased.")
		}
		start()
	}

	public var isBiometricUnlockAvailable: Bool {
		keyStore.isAvailable
	}

	public var isBiometricUnlockEnabled: Bool {
		biometricUnlock.isEnabled
	}

	public var touchID: TouchID {
		biometricUnlock.state
	}

	public var shake: Shake {
		biometricUnlock.shake
	}

	public static var hasSecureEnclave: Bool {
		MachineKey.isAvailable
	}

	public func enableBiometricUnlock(password: String) async -> Failure? {
		guard phase == .unlocked, let store, let unlockParameters else {
			return .unexpected("Unlock Native Note to turn on Touch ID unlock.")
		}
		guard keyStore.isAvailable else { return .unexpected("Touch ID is not available on this Mac.") }
		defer { biometricUnlock.refresh() }
		do {
			let key = try await Unlock.provenKey(password: password, parameters: unlockParameters, in: directory)
			return await biometricUnlock.turnOn(with: key) {
				self.store === store && self.unlockParameters == unlockParameters && self.passwordChange == nil
			}
		} catch {
			return Failure(error)
		}
	}

	public func disableBiometricUnlock() {
		if let failure = biometricUnlock.turnOff() { self.failure = failure }
	}

	public func changePassword(from current: String, to new: String) async -> Failure? {
		guard phase == .unlocked, let store, let unlockParameters else {
			return .unexpected("Unlock Native Note to change the password.")
		}
		guard passwordChange == nil else { return .unexpected("The password is already being changed.") }
		let change = Task { () -> Failure? in
			defer {
				passwordChange = nil
				biometricUnlock.refresh()
			}
			do {
				let changed = try await Unlock.changePassword(
					from: current,
					to: new,
					parameters: unlockParameters,
					store: store,
					in: directory,
					storedKey: keyStore,
					calibrate: calibrate
				)
				if self.store === store { self.unlockParameters = changed.parameters }
				return nil
			} catch {
				return Failure(error)
			}
		}
		passwordChange = change
		return await change.value
	}

	public func appBecameActive() {
		biometricUnlock.appBecameActive()
		Task { await syncNow() }
	}

	public func appResignedActive() {
		Task { await syncNow() }
		biometricUnlock.appResignedActive()
	}

	public func tryTouchIDAgain() {
		biometricUnlock.tryAgain()
	}

	public func cancelTurningOnTouchID() {
		biometricUnlock.cancelTurningOn()
	}

	public func listen(through glyph: LAAuthenticationView) async {
		let failure = await biometricUnlock.listen(through: glyph) { key in
			await self.openLibrary { try await Unlock.open(key: key, in: self.directory) }
		}
		if let failure { self.failure = failure }
	}

	public static func isEncryptedExport(at url: URL) -> Bool {
		let head = try? FileHandle(forReadingFrom: url).read(upToCount: 64)
		return head.map(ExportEnvelope.isEncrypted) ?? false
	}

	@discardableResult
	public func exportLibrary(to url: URL, passphrase: String?) async -> Bool {
		guard phase == .unlocked, store != nil else { return false }
		let notes = notes
		let parameters = exportParameters
		do {
			try await BlockingWork.run {
				let archive = try LibraryArchive.archive(notes)
				let file = try LibraryArchive.importable(passphrase.map { try ExportEnvelope.seal(archive, passphrase: $0, parameters: parameters) } ?? archive)
				try file.write(to: url, options: .atomic)
			}
			return true
		} catch {
			report(error, as: "The notes could not be exported.")
			return false
		}
	}

	@discardableResult
	public func importLibrary(from url: URL, passphrase: String?) async -> ImportSummary? {
		guard let store, !isImporting else { return nil }
		isImporting = true
		defer { isImporting = false }
		let incoming: [Note]
		do {
			incoming = try await BlockingWork.run {
				guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= LibraryArchive.maximumSize else {
					throw LibraryArchive.Failure.tooLarge
				}
				let file = try Data(contentsOf: url, options: .mappedIfSafe)
				try ExportEnvelope.refuseNewerVersion(file)
				return try LibraryArchive.notes(in: passphrase.map { try ExportEnvelope.open(file, passphrase: $0) } ?? file)
			}
		} catch {
			report(error, as: "The file could not be imported.")
			return nil
		}

		guard store === self.store else { return ImportSummary(notImported: incoming.count) }
		let added: [Note]
		do {
			added = try await store.insertMissing(incoming)
		} catch {
			guard store === self.store else { return ImportSummary(notImported: incoming.count) }
			report(error, as: "The file could not be imported.")
			return nil
		}
		if store === self.store {
			let shown = Set(notes.map(\.id))
			notes += added.filter { !shown.contains($0.id) }
			sync.soon()
		}
		return ImportSummary(added: added.count, skipped: incoming.count - added.count)
	}

	nonisolated static func search(_ store: NoteStore, for text: String) async throws -> [Note] {
		try await store.search(text)
	}

	func scheduleSave(_ note: Note, to store: NoteStore) {
		scheduler.schedule(note.id) { [weak self] in
			do {
				if case let .copied(copy) = try await store.save(note) {
					await self?.saveBecameCopy(note, copy: copy, in: store)
				}
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

	public func lockWhileAway() {
		awayEvents += 1
		guard phase == .unlocked else { return }
		Task { await lock() }
	}

	@discardableResult
	private func openLibrary(onboarding: Bool = false, _ open: @escaping () async throws -> Unlock.Unlocked) async -> Error? {
		failure = nil
		let away = awayEvents
		_ = await passwordChange?.value
		do {
			let unlocked = try await open()
			let opened = unlocked.store
			let loaded = try await opened.liveNotes()
			store = opened
			unlockParameters = unlocked.parameters
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
			guard away == awayEvents else {
				await lock()
				return nil
			}
			selection = groups.first?.notes.first?.id
			isOnboarding = onboarding
			phase = .unlocked
			biometricUnlock.refresh()
			await sync.start(opened)
			return nil
		} catch {
			if case Unlock.Failure.alreadySetUp = error { phase = .locked }
			failure = Failure(error)
			return error
		}
	}

	func write(_ action: String, _ body: (NoteStore) async throws -> Void) async -> Bool {
		guard let store else { return false }
		do {
			try await body(store)
			return true
		} catch {
			if store === self.store { report(error, as: action) }
			return false
		}
	}

	func report(_ error: Error, as title: String) {
		let failure = Failure(error)
		if case let .unexpected(reason) = failure {
			self.failure = .failed(reason, title: title)
		} else {
			self.failure = failure
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
