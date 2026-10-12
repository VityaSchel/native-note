import CryptoKit
import Foundation

extension AppModel {
	public struct SyncStatus: Equatable {
		public enum Phase: Equatable {
			case off
			case idle
			case syncing
			case failed(String)
		}

		public var phase: Phase
		public var server: String?
		public var lastSynced: Date?
		public var problems: [String]

		public init(phase: Phase = .off, server: String? = nil, lastSynced: Date? = nil, problems: [String] = []) {
			self.phase = phase
			self.server = server
			self.lastSynced = lastSynced
			self.problems = problems
		}
	}

	/// Words of a new Recovery key, and the positions the user types back to prove they kept them.
	public struct RecoveryPhrase: Equatable {
		public let words: [String]
		public let checked: [Int]
	}

	public enum SyncSetupFailure: Error, Equatable {
		case invalidServer
		case invalidAPIKey
		case unreachable(String)
		case refused
		case serverHasLibrary
		case rotatedElsewhere
		case serverBehind
		case wordsDoNotMatch
		case phraseDoesNotOpen
		case failed(String)

		public var message: String {
			switch self {
			case .invalidServer: "Enter the server's address, starting with http:// or https://."
			case .invalidAPIKey: "Enter the 64-character API key from the server's api-key file."
			case let .unreachable(reason): "The server could not be reached. \(reason)"
			case .refused: "The server did not accept this API key."
			case .serverHasLibrary: "This server already holds a library. Restoring a library from a server comes in a later version of Native Note."
			case .rotatedElsewhere: "The recovery phrase was changed on another device, so this phrase was not saved. Enter the current phrase to continue."
			case .serverBehind: "The server holds an older recovery phrase than this Mac last saw. It may have been restored from a backup."
			case .wordsDoNotMatch: "Those words don't match the phrase. Check what you wrote down."
			case .phraseDoesNotOpen: "This phrase does not open this library's key."
			case let .failed(reason): reason
			}
		}
	}

	struct RecoverySession {
		let settings: SyncSettings
		let recoveryKey: SymmetricKey
		let phrase: RecoveryPhrase
	}

	/// Returns once a sync that started after the call has finished; requests made meanwhile share the next one.
	public func syncNow() async {
		syncRequests += 1
		let wanted = syncRequests
		if syncLoop == nil {
			syncLoop = Task {
				while syncedThrough < syncRequests {
					let covered = syncRequests
					await syncOnce()
					syncedThrough = covered
				}
				syncLoop = nil
			}
		}
		while syncedThrough < wanted, let syncLoop {
			await syncLoop.value
		}
	}

	private func syncOnce() async {
		guard let engine, let store else { return }
		idleSync?.cancel()
		syncStatus.phase = .syncing
		await scheduler.flushAll()
		do {
			let applied = try await engine.sync { try await self.commit($0, to: store) }
			guard store === self.store else { return }
			syncStatus.problems = applied.problems.map(Self.describe)
			syncStatus.lastSynced = Date()
			syncStatus.phase = .idle
		} catch {
			guard store === self.store else { return }
			syncStatus.phase = .failed(Self.describe(error))
		}
	}

	func syncSoon() {
		guard engine != nil else { return }
		idleSync?.cancel()
		idleSync = Task { [syncDelay] in
			try? await Task.sleep(for: syncDelay)
			guard !Task.isCancelled else { return }
			idleSync = nil
			await syncNow()
		}
	}

	func startSync(_ store: NoteStore) async {
		guard let settings = try? await store.syncSettings(), store === self.store else { return }
		engine = SyncEngine(store: store, settings: settings, transport: makeTransport(settings.server))
		syncStatus = SyncStatus(phase: .idle, server: settings.server.absoluteString)
		Task { await syncNow() }
	}

	func stopSync() {
		idleSync?.cancel()
		idleSync = nil
		engine = nil
		recovery = nil
		syncStatus = SyncStatus()
	}

	public func prepareSync(server: String, apiKey: String) async -> Result<RecoveryPhrase, SyncSetupFailure> {
		guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
			["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
		else { return .failure(.invalidServer) }
		guard let apiKey = EnvelopeKey.apiKey(fromHex: apiKey) else { return .failure(.invalidAPIKey) }
		let settings = SyncSettings(server: url, apiKey: apiKey, contentKey: SymmetricKey(size: .bits256))
		do {
			guard try await flow(settings).storedVersion() == 0 else { return .failure(.serverHasLibrary) }
		} catch {
			return .failure(Self.setupFailure(error))
		}
		return newPhrase(for: settings).map(Result.success) ?? .failure(.failed("The recovery wordlist is missing."))
	}

	public func finishSync(answers: [String]) async -> SyncSetupFailure? {
		guard let store, let session = recovery, engine == nil else { return .failed("Start setting up sync again.") }
		guard Self.matches(answers, session.phrase) else { return .wordsDoNotMatch }
		do {
			let pin = try await flow(session.settings).put(session.settings.contentKey, under: session.recoveryKey, pin: 0)
			try await store.enableSync(session.settings, pin: pin)
		} catch RecoveryFlow.Failure.rotatedElsewhere {
			return .serverHasLibrary
		} catch {
			return Self.setupFailure(error)
		}
		recovery = nil
		await startSync(store)
		return nil
	}

	public func prepareRotation() async -> RecoveryPhrase? {
		guard let settings = try? await store?.syncSettings() else { return nil }
		return newPhrase(for: settings)
	}

	public func finishRotation(answers: [String]) async -> SyncSetupFailure? {
		guard let store, let session = recovery else { return .failed("Start changing the phrase again.") }
		guard Self.matches(answers, session.phrase) else { return .wordsDoNotMatch }
		do {
			let pin = try await flow(session.settings).put(session.settings.contentKey, under: session.recoveryKey, pin: try await store.pin())
			try await store.setPin(pin)
		} catch {
			return Self.setupFailure(error)
		}
		recovery = nil
		return nil
	}

	/// After another device rotated: the current phrase re-pins this Mac so rotation can run again.
	public func adoptCurrentPhrase(_ text: String) async -> SyncSetupFailure? {
		guard let store, let settings = try? await store.syncSettings() else { return .failed("Sync is not set up.") }
		let words = text.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
		guard let recoveryKey = Mnemonic.key(from: words) else { return .phraseDoesNotOpen }
		do {
			guard let pin = try await flow(settings).pin(opening: settings.contentKey, under: recoveryKey) else { return .phraseDoesNotOpen }
			try await store.setPin(pin)
		} catch {
			return Self.setupFailure(error)
		}
		return nil
	}

	public func cancelRecovery() {
		recovery = nil
	}

	private func newPhrase(for settings: SyncSettings) -> RecoveryPhrase? {
		let recoveryKey = SymmetricKey(size: .bits256)
		guard let words = Mnemonic.words(for: recoveryKey) else { return nil }
		let phrase = RecoveryPhrase(words: words, checked: Array(words.indices.shuffled().prefix(3)).sorted())
		recovery = RecoverySession(settings: settings, recoveryKey: recoveryKey, phrase: phrase)
		return phrase
	}

	private func flow(_ settings: SyncSettings) -> RecoveryFlow {
		RecoveryFlow(connection: SyncConnection(apiKey: settings.apiKey, transport: makeTransport(settings.server)))
	}

	/// Commits with no due save landing under it; an edit typed meanwhile on a note a pull replaced moves to its copy.
	private func commit(_ commit: Commit, to store: NoteStore) async throws -> Applied {
		scheduler.hold()
		defer { scheduler.release() }
		await scheduler.flushAll()
		let applied = try await store.commit(commit)
		await reconcile(applied, in: store)
		return applied
	}

	func reconcile(_ applied: Applied, in store: NoteStore) async {
		guard store === self.store else { return }
		for (id, row) in applied.changed {
			if scheduler.isPending(id), applied.pulled.contains(id) {
				moveEdit(of: id, to: applied.copies[id] ?? UUID(), in: store)
			} else if scheduler.isPending(id), let index = notes.firstIndex(where: { $0.id == id }) {
				notes[index].v = row.v
				continue
			}
			show(row)
		}
		for (original, copy) in applied.copies where selection == original {
			selection = copy
		}
	}

	/// A save whose note a pull replaced after the edit began landed as a copy: the editor and any later typing follow it.
	func saveBecameCopy(_ note: Note, copy: UUID, in store: NoteStore) async {
		guard store === self.store else { return }
		if notes.contains(where: { $0.id == note.id }) {
			moveEdit(of: note.id, to: copy, in: store)
		} else {
			show(Note(id: copy, body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt, dirty: true))
		}
		if let original = try? await store.note(id: note.id) { show(original) }
	}

	private func moveEdit(of id: UUID, to copyID: UUID, in store: NoteStore) {
		guard var edit = notes.first(where: { $0.id == id }) else { return }
		scheduler.cancel(id)
		edit.id = copyID
		edit.v = 0
		edit.dirty = true
		show(edit)
		scheduleSave(edit, to: store)
		if selection == id { selection = copyID }
	}

	private func show(_ note: Note) {
		let index = notes.firstIndex { $0.id == note.id }
		switch (index, note.deleted) {
		case let (index?, false): notes[index] = note
		case let (index?, true): notes.remove(at: index)
		case (nil, false): notes.append(note)
		case (nil, true): break
		}
	}

	private static func matches(_ answers: [String], _ phrase: RecoveryPhrase) -> Bool {
		answers.count == phrase.checked.count
			&& zip(answers, phrase.checked).allSatisfy { $0.trimmingCharacters(in: .whitespaces).lowercased() == phrase.words[$1] }
	}

	private static func setupFailure(_ error: Error) -> SyncSetupFailure {
		switch error {
		case SyncError.refused, SyncError.unopenable: .refused
		case RecoveryFlow.Failure.serverHasLibrary: .serverHasLibrary
		case RecoveryFlow.Failure.rotatedElsewhere: .rotatedElsewhere
		case RecoveryFlow.Failure.serverBehind: .serverBehind
		case let error as URLError: .unreachable(error.localizedDescription)
		default: .failed(describe(error))
		}
	}

	private static func describe(_ problem: SyncProblem) -> String {
		switch problem {
		case .serverBehind: "The server holds less than this Mac has seen. It may have been restored from a backup."
		case .unverifiableChange: "A change on the server could not be read with this library's key, so it was skipped."
		case .tooLarge: "A note is larger than 1 MB, so it stays on this Mac until it is shorter."
		}
	}

	private static func describe(_ error: Error) -> String {
		switch error {
		case SyncError.refused, SyncError.unopenable: "The server did not accept this Mac's API key."
		case SyncError.serverFault: "The server could not store the changes. Its disk may be full."
		case SyncError.protocolViolation: "The server sent a reply Native Note does not understand."
		case let error as URLError: "The server could not be reached. \(error.localizedDescription)"
		default: Failure.reason(for: error)
		}
	}
}
