import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
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
	public private(set) var isImporting = false
	public private(set) var isBiometricUnlockEnabled = false
	public private(set) var touchID = TouchID.hidden
	public private(set) var shake = Shake()
	public var selection: UUID? {
		didSet {
			guard let previous = oldValue, previous != selection else { return }
			Task { await scheduler.flush(previous) }
		}
	}
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

	public var libraryDirectory: URL {
		directory
	}

	public var noteCount: Int {
		notes.count
	}

	private let directory: URL
	private let scheduler: SaveScheduler
	private let makeParameters: @Sendable () throws -> UnlockParameters
	private let calibrate: @Sendable () throws -> Argon2.Parameters
	private let searchNotes: @Sendable (NoteStore, String) async throws -> [Note]
	private let exportParameters: Argon2.Parameters
	private let keyStore: any UnlockKeyStore
	private let shakeTimer: SaveScheduler.Sleep
	private var unlockParameters: UnlockParameters?
	private var passwordChangesInFlight = 0
	private var store: NoteStore?
	private var retiring: NoteStore?
	private var failingSaves: [UUID: FailingSave] = [:]
	private var searchFailing = false
	private var matches: [UUID]?
	private var biometrics = BiometricAvailability.unavailable
	private var isActive = false
	private var isCheckingPassword = false
	private var isOpeningWithTouchID = false
	private var touchIDStop: TouchID.Stop?
	private var evaluating: LAContext?
	private var confirmation: CheckedContinuation<StoredKeyRead, Error>?

	public convenience init() {
		self.init(directory: AppLock.directory)
	}

	public convenience init(libraryAt directory: URL, keyStore: (any UnlockKeyStore)? = nil, bindsToThisMac: Bool = true) {
		self.init(directory: directory, makeParameters: bindsToThisMac ? Unlock.makeParameters : Unlock.makeUnboundParameters, keyStore: keyStore)
	}

	init(
		directory: URL,
		scheduler: SaveScheduler = SaveScheduler(),
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.makeParameters,
		calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { try Argon2.calibrateMemory() },
		searchNotes: @escaping @Sendable (NoteStore, String) async throws -> [Note] = AppModel.search,
		exportParameters: Argon2.Parameters = Argon2.floor,
		keyStore: (any UnlockKeyStore)? = nil,
		shakeTimer: @escaping SaveScheduler.Sleep = { try await Task.sleep(for: $0) }
	) {
		self.directory = directory
		self.scheduler = scheduler
		self.makeParameters = makeParameters
		self.calibrate = calibrate
		self.searchNotes = searchNotes
		self.exportParameters = exportParameters
		self.keyStore = keyStore ?? KeychainUnlockKeyStore(directory: directory)
		self.shakeTimer = shakeTimer
	}

	public func start() {
		phase = AppLock.parameterFiles(in: directory).isEmpty ? .needsSetup : .locked
		touchIDStop = nil
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
		guard !isOpeningWithTouchID else { return }
		isCheckingPassword = true
		settleTouchID()
		let error = await openLibrary { try await Unlock.open(password: password, in: self.directory) }
		if let error, Failure(error) == .wrongPassword { startShake() }
		isCheckingPassword = false
		settleTouchID()
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
		cancelTurningOnTouchID()
		phase = .locked
		touchIDStop = nil
		selection = nil
		notes = []
		store = nil
		failure = nil
		failingSaves = [:]
		searchFailing = false
		unlockParameters = nil
		refreshBiometricUnlock()
		await scheduler.flushAll()
		guard let closing else { return }
		if unsavedReason == nil { await closing.close() } else { retiring = closing }
	}

	@discardableResult
	public func flushPendingSaves() async -> Bool {
		await scheduler.flushAll()
	}

	public func close() async {
		cancelTurningOnTouchID()
		await scheduler.flushAll()
		let open = [store, retiring].compactMap(\.self)
		store = nil
		retiring = nil
		for store in open { await store.close() }
	}

	public func createNote() async {
		let now = Date()
		let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now, dirty: true)
		guard await write({ try await $0.save(note) }) else { return }
		notes.insert(note, at: 0)
		selection = note.id
	}

	public func edit(_ id: UUID, _ body: String) {
		guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].body != body else { return }
		var edited = notes[index]
		edited.body = body
		edited.updatedAt = Date()
		edited.dirty = true
		notes[index] = edited

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
		guard phase == .locked, !isOpeningWithTouchID else { return }
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

	public var isBiometricUnlockAvailable: Bool {
		keyStore.isAvailable
	}

	public static var hasSecureEnclave: Bool {
		MachineKey.isAvailable
	}

	public func enableBiometricUnlock(password: String) async -> Failure? {
		guard phase == .unlocked, let store, let unlockParameters else {
			return .unexpected("Unlock Native Note to turn on Touch ID unlock.")
		}
		guard keyStore.isAvailable else { return .unexpected("Touch ID is not available on this Mac.") }
		defer { refreshBiometricUnlock() }
		let isStillCurrent = { self.store === store && self.unlockParameters == unlockParameters && self.passwordChangesInFlight == 0 }
		let key: SymmetricKey
		do {
			key = try await Unlock.provenKey(password: password, parameters: unlockParameters, in: directory)
		} catch {
			return Failure(error)
		}
		guard isStillCurrent() else {
			try? keyStore.delete()
			return nil
		}
		do {
			try keyStore.save(key)
			let read = try await touchToConfirm()
			guard case let .key(confirmed) = read else {
				try? keyStore.delete()
				switch read {
				case .lockedOut: return .unexpected("Touch ID unlock could not be turned on. Touch ID is locked.")
				case .unavailable: return .unexpected("Touch ID unlock could not be turned on. Touch ID is not available.")
				case .key, .missed, .cancelled: return nil
				}
			}
			guard isStillCurrent() else {
				try? keyStore.delete()
				return nil
			}
			guard confirmed == key else {
				try? keyStore.delete()
				return .unexpected("Touch ID unlock could not be turned on. Try again.")
			}
			return nil
		} catch {
			try? keyStore.delete()
			return .unexpected("Touch ID unlock could not be turned on. \((error as? KeychainFailure)?.message ?? error.localizedDescription)")
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

	public func changePassword(from current: String, to new: String) async -> Failure? {
		guard phase == .unlocked, let store, let unlockParameters else {
			return .unexpected("Unlock Native Note to change the password.")
		}
		passwordChangesInFlight += 1
		defer {
			passwordChangesInFlight -= 1
			refreshBiometricUnlock()
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

	public func appBecameActive() {
		isActive = true
		refreshBiometricUnlock()
	}

	public func appResignedActive() {
		isActive = false
		if touchIDStop == .cancel { touchIDStop = nil }
		settleTouchID()
	}

	public func tryTouchIDAgain() {
		guard case .needsClick = touchID else { return }
		touchIDStop = nil
		settleTouchID()
	}

	public func cancelTurningOnTouchID() {
		guard confirmation != nil else { return }
		try? keyStore.delete()
		finishConfirmation(.success(.cancelled))
	}

	public func listen(through glyph: LAAuthenticationView) async {
		guard case let .listening(context) = touchID, glyph.context === context, glyph.window != nil, evaluating !== context else { return }
		evaluating = context
		let confirming = confirmation != nil
		let read: Result<StoredKeyRead, Error>
		do {
			read = .success(try await keyStore.read(through: context, reason: confirming ? "turn on Touch ID unlock" : "unlock your notes"))
		} catch {
			read = .failure(error)
		}
		if evaluating === context { evaluating = nil }
		guard touchID == .listening(context) else { return }
		if confirming {
			confirm(with: read)
		} else {
			await unlock(with: read)
		}
	}

	private func unlock(with read: Result<StoredKeyRead, Error>) async {
		switch read {
		case let .success(.key(key)):
			isOpeningWithTouchID = true
			settleTouchID()
			let error = await openLibrary { try await Unlock.open(key: key, in: self.directory) }
			isOpeningWithTouchID = false
			guard let error else {
				settleTouchID()
				return
			}
			if case Unlock.Failure.storedKeyRejected = error {
				forgetStoredKey(explaining: Failure.reason(for: error))
			} else {
				waitForClick(after: .failure)
			}
		case .success(.missed):
			if keyStore.availability == .lockedOut { biometrics = .lockedOut }
			startShake()
		case .success(.cancelled):
			waitForClick(after: .cancel)
		case .success(.lockedOut):
			biometrics = .lockedOut
			touchIDStop = nil
			settleTouchID()
		case .success(.unavailable):
			biometrics = .unavailable
			settleTouchID()
		case .failure:
			forgetStoredKey(explaining: "Touch ID could not read the unlock key. Unlock with your password.")
		}
	}

	private func confirm(with read: Result<StoredKeyRead, Error>) {
		switch read {
		case .success(.missed):
			waitForClick(after: .miss)
		case .success(.cancelled):
			waitForClick(after: .cancel)
		default:
			finishConfirmation(read)
		}
	}

	private func touchToConfirm() async throws -> StoredKeyRead {
		guard confirmation == nil else { return .cancelled }
		return try await withCheckedThrowingContinuation { continuation in
			confirmation = continuation
			touchIDStop = nil
			settleTouchID()
		}
	}

	private func finishConfirmation(_ read: Result<StoredKeyRead, Error>) {
		guard let confirmation else { return }
		self.confirmation = nil
		touchIDStop = nil
		settleTouchID()
		confirmation.resume(with: read)
	}

	private func startShake() {
		guard !shake.isRunning else { return }
		shake.count += 1
		shake.isRunning = true
		settleTouchID()
		Task { [shakeTimer] in
			try? await shakeTimer(Shake.duration)
			shake.isRunning = false
			settleTouchID()
		}
	}

	private func waitForClick(after stop: TouchID.Stop) {
		touchIDStop = stop
		settleTouchID()
	}

	private func forgetStoredKey(explaining message: String) {
		if (try? keyStore.delete()) == nil { touchIDStop = .failure }
		refreshBiometricUnlock()
		failure = .unexpected(message)
	}

	private func refreshBiometricUnlock() {
		isBiometricUnlockEnabled = confirmation == nil && keyStore.hasKey()
		biometrics = keyStore.availability
		settleTouchID()
	}

	private func settleTouchID() {
		let next = nextTouchID()
		guard next != touchID else { return }
		if case let .listening(context) = touchID { context.invalidate() }
		touchID = next
	}

	private func nextTouchID() -> TouchID {
		let confirming = confirmation != nil
		guard confirming || (phase == .locked && isBiometricUnlockEnabled && biometrics != .unavailable) else { return .hidden }
		if isOpeningWithTouchID { return .working }
		if !confirming, biometrics == .lockedOut { return .lockedOut }
		if let touchIDStop { return .needsClick(after: touchIDStop) }
		if isCheckingPassword { return .paused(.checkingPassword) }
		if !confirming, shake.isRunning { return .paused(.shaking) }
		if !isActive { return .paused(.inBackground) }
		if case .listening = touchID { return touchID }
		return .listening(LAContext())
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
		for (index, var note) in incoming.enumerated() {
			guard store === self.store else { return stopped(at: index) }
			do {
				if try await store.note(id: note.id) != nil {
					summary.skipped += 1
					continue
				}
				note.v = 0
				try await store.save(note)
			} catch {
				guard store === self.store else { return stopped(at: index) }
				report(error)
				return nil
			}
			summary.added += 1
			if store === self.store { notes.append(note) }
		}
		return summary
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

	@discardableResult
	private func openLibrary(_ open: @escaping () async throws -> Unlock.Unlocked) async -> Error? {
		failure = nil
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
			phase = .unlocked
			refreshBiometricUnlock()
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
