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

	/// A server with no library gets a new one under a new phrase; one that holds a library is joined with its phrase.
	public enum SyncSetupStart: Equatable {
		case newLibrary(RecoveryPhrase)
		case existingLibrary
		/// A library that keeps its key found itself on this server and syncs again, with no words to enter.
		case reattached
	}

	public enum SyncSetupFailure: Error, Equatable {
		case invalidServer
		case invalidAPIKey
		case unreachable(String)
		case refused
		case answered(status: Int)
		case serverHasLibrary
		case serverHoldsAnotherLibrary
		case serverHasNoLibrary
		case serverLostLibrary
		case alreadySetUp
		case rotatedElsewhere
		case serverBehind
		case outcomeUnknown
		case wordsDoNotMatch
		case phraseDoesNotOpen
		case failed(String)

		public var message: String {
			switch self {
			case .invalidServer: "Enter the server's address, starting with http:// or https://."
			case .invalidAPIKey: "Enter the 64-character API key from the server's api-key file."
			case let .unreachable(reason): "The server could not be reached. \(reason)"
			case .refused: "The server did not accept this API key, or a proxy in front of it changed the request. A proxy must forward HTTP/1.1 to the server's root path."
			case let .answered(status): AppModel.statusMessage(status)
			case .serverHasLibrary: "This server now holds a library. Enter its recovery phrase to sync this Mac with it."
			case .serverHoldsAnotherLibrary: "This server holds another library. Native Note cannot merge two libraries; choose a server that holds this one, or an empty one."
			case .serverHasNoLibrary: "This server no longer holds a library. Continue to start a new one."
			case .serverLostLibrary: "The server no longer holds this library as this Mac last saw it. It may have been reset or restored from a backup."
			case .alreadySetUp: "Sync is already set up on this Mac."
			case .rotatedElsewhere: "The recovery phrase was changed on another device, so this phrase was not saved. Enter the current phrase to continue."
			case .serverBehind: "The server holds an older recovery phrase than this Mac last saw. It may have been restored from a backup."
			case .outcomeUnknown: "The server's answer did not arrive, so this phrase may already be in effect. Keep it, and any phrase it replaces, and try again."
			case .wordsDoNotMatch: "Those words don't match the phrase. Check what you wrote down."
			case .phraseDoesNotOpen: "This phrase does not open the library on this server."
			case let .failed(reason): reason
			}
		}
	}

	struct RecoverySession {
		let settings: SyncSettings
		let recoveryKey: SymmetricKey
		let phrase: RecoveryPhrase
		/// This library, with its own Content key, goes to an empty server.
		var moving = false
	}

	/// Returns once a sync that started after the call has finished; requests made meanwhile share the next one.
	public func syncNow() async {
		syncRequests += 1
		let wanted = syncRequests
		if syncLoop == nil {
			syncLoop = Task {
				while syncedThrough < syncRequests, !Task.isCancelled {
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

	/// Cancels a sync in flight, whose keys and pulled text go with it; await the returned loop before closing the store it uses.
	@discardableResult
	func stopSync() -> Task<Void, Never>? {
		let loop = syncLoop
		let change = keyChange
		loop?.cancel()
		change?.cancel()
		keyChange = nil
		idleSync?.cancel()
		idleSync = nil
		engine = nil
		recovery = nil
		syncStatus = SyncStatus()
		guard loop != nil || change != nil else { return nil }
		return Task {
			await loop?.value
			_ = await change?.value
		}
	}

	public func prepareSync(server: String, apiKey: String) async -> Result<SyncSetupStart, SyncSetupFailure> {
		do {
			let endpoint = try Self.endpoint(server: server, apiKey: apiKey)
			if let store, let kept = try await store.keptLibrary() {
				return try await reattachOrMove(kept, to: endpoint.server, apiKey: endpoint.apiKey, in: store)
			}
			let settings = SyncSettings(server: endpoint.server, apiKey: endpoint.apiKey, contentKey: SymmetricKey(size: .bits256))
			guard try await flow(settings).storedVersion() == 0 else { return .success(.existingLibrary) }
			return newPhrase(for: settings).map { .success(.newLibrary($0)) } ?? .failure(.failed("The recovery wordlist is missing."))
		} catch {
			return .failure(Self.setupFailure(error))
		}
	}

	/// Restore and add-device, per clients/DESIGN.md § Recovery flow: nothing is stored unless the phrase opens the server's blob.
	public func joinSync(server: String, apiKey: String, phrase: PhraseEntry) async -> SyncSetupFailure? {
		guard let store, engine == nil else { return .alreadySetUp }
		guard let recoveryKey = phrase.key else { return .phraseDoesNotOpen }
		do {
			let endpoint = try Self.endpoint(server: server, apiKey: apiKey)
			guard let joined = try await flow(endpoint.server, endpoint.apiKey).join(under: recoveryKey) else { return .phraseDoesNotOpen }
			try Task.checkCancellation()
			try await store.enableSync(SyncSettings(server: endpoint.server, apiKey: endpoint.apiKey, contentKey: joined.contentKey), pin: joined.pin)
		} catch {
			return Self.setupFailure(error)
		}
		recovery = nil
		await startSync(store)
		return nil
	}

	public func finishSync(answers: [String]) async -> SyncSetupFailure? {
		guard let store, let session = recovery, engine == nil || session.moving else { return .failed("Start setting up sync again.") }
		guard Self.matches(answers, session.phrase) else { return .wordsDoNotMatch }
		do {
			let pin = try await flow(session.settings).put(session.settings.contentKey, under: session.recoveryKey, pin: 0)
			if session.moving {
				await stopSync()?.value
				try await store.moveSync(to: session.settings, pin: pin)
			} else {
				try await store.enableSync(session.settings, pin: pin)
			}
		} catch RecoveryFlow.Failure.rotatedElsewhere {
			return .serverHasLibrary
		} catch {
			return Self.setupFailure(error)
		}
		recovery = nil
		await startSync(store)
		return nil
	}

	/// After the server's key was replaced, as for a lost Mac. Locking cancels it, so neither key outlives the lock.
	public func changeAPIKey(_ hex: String) async -> SyncSetupFailure? {
		guard let store else { return .failed("Sync is not set up.") }
		guard let apiKey = EnvelopeKey.apiKey(fromHex: hex) else { return .invalidAPIKey }
		let change = Task { [makeTransport] in await Self.adopt(apiKey, in: store, makeTransport) }
		keyChange = change
		let failure = await withTaskCancellationHandler { await change.value } onCancel: { change.cancel() }
		guard keyChange == change else { return failure }
		keyChange = nil
		guard failure == nil, store === self.store else { return failure }
		await stopSync()?.value
		await startSync(store)
		return nil
	}

	/// Keeps the new key only once the server it reaches holds this library: a blob at or past the pin, and the write this Mac's last pull ended on or one that replaced it.
	private static func adopt(_ apiKey: SymmetricKey, in store: NoteStore, _ makeTransport: @Sendable (URL) -> any SyncTransport) async -> SyncSetupFailure? {
		do {
			guard let settings = try await store.syncSettings() else { return .failed("Sync is not set up.") }
			let connection = SyncConnection(apiKey: apiKey, transport: makeTransport(settings.server))
			let stored = try await RecoveryFlow(connection: connection).storedVersion()
			guard stored > 0 else { return .serverLostLibrary }
			guard stored >= (try await store.pin()) else { return .serverBehind }
			if let mark = try await store.lastPulled(), try await !SyncEngine.holds(mark, through: connection, since: store.since()) {
				return .serverLostLibrary
			}
			try Task.checkCancellation()
			try await store.setAPIKey(apiKey)
			return nil
		} catch {
			return setupFailure(error)
		}
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

	/// Stops syncing and forgets the server and its key; the notes stay, and so does what a later Set Up Sync needs to find this library again.
	public func turnOffSync() async -> Bool {
		guard let store else { return false }
		await stopSync()?.value
		guard await write("Sync could not be turned off.", { try await $0.disconnectSync() }) else {
			await startSync(store)
			return false
		}
		return true
	}

	/// A server that holds this library takes it back at once; an empty one gets it under a new phrase; another library is refused.
	private func reattachOrMove(_ kept: NoteStore.KeptLibrary, to server: URL, apiKey: SymmetricKey, in store: NoteStore) async throws -> Result<SyncSetupStart, SyncSetupFailure> {
		let connection = SyncConnection(apiKey: apiKey, transport: makeTransport(server))
		let stored = try await RecoveryFlow(connection: connection).storedVersion()
		guard stored > 0 else {
			let settings = SyncSettings(server: server, apiKey: apiKey, contentKey: kept.contentKey)
			guard let phrase = newPhrase(for: settings) else { return .failure(.failed("The recovery wordlist is missing.")) }
			recovery?.moving = true
			return .success(.newLibrary(phrase))
		}
		guard stored >= kept.pin else { return .failure(.serverBehind) }
		if let mark = kept.mark, try await !SyncEngine.holds(mark, through: connection, since: kept.since) {
			return .failure(.serverHoldsAnotherLibrary)
		}
		try Task.checkCancellation()
		await stopSync()?.value
		try await store.reattachSync(server: server, apiKey: apiKey)
		guard store === self.store else { return .success(.reattached) }
		await startSync(store)
		return .success(.reattached)
	}

	private func newPhrase(for settings: SyncSettings) -> RecoveryPhrase? {
		let recoveryKey = SymmetricKey(size: .bits256)
		guard let words = Mnemonic.words(for: recoveryKey) else { return nil }
		let phrase = RecoveryPhrase(words: words, checked: Array(words.indices.shuffled().prefix(3)).sorted())
		recovery = RecoverySession(settings: settings, recoveryKey: recoveryKey, phrase: phrase)
		return phrase
	}

	private func flow(_ settings: SyncSettings) -> RecoveryFlow {
		flow(settings.server, settings.apiKey)
	}

	private func flow(_ server: URL, _ apiKey: SymmetricKey) -> RecoveryFlow {
		RecoveryFlow(connection: SyncConnection(apiKey: apiKey, transport: makeTransport(server)))
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

	private static func endpoint(server: String, apiKey: String) throws(SyncSetupFailure) -> (server: URL, apiKey: SymmetricKey) {
		guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
			["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
		else { throw .invalidServer }
		guard let apiKey = EnvelopeKey.apiKey(fromHex: apiKey) else { throw .invalidAPIKey }
		return (url, apiKey)
	}

	private static func setupFailure(_ error: Error) -> SyncSetupFailure {
		switch error {
		case let failure as SyncSetupFailure: failure
		case is NoteStore.SyncAlreadySetUp: .alreadySetUp
		case SyncError.refused(400), SyncError.unopenable: .refused
		case let SyncError.refused(status): .answered(status: status)
		case RecoveryFlow.Failure.noLibrary: .serverHasNoLibrary
		case RecoveryFlow.Failure.serverHasLibrary: .serverHasLibrary
		case RecoveryFlow.Failure.rotatedElsewhere: .rotatedElsewhere
		case RecoveryFlow.Failure.serverBehind: .serverBehind
		case RecoveryFlow.Failure.outcomeUnknown: .outcomeUnknown
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

	/// Only a 400 can mean a refused key, though a proxy that changed the request gets one too; the rest come from a proxy, a redirect or a server fault.
	nonisolated static func statusMessage(_ status: Int) -> String {
		switch status {
		case 413: "The server or a proxy in front of it refused a request this large. A proxy must accept request bodies of at least 2 MiB + 28 B, such as 3 MiB."
		case 500 ... 599: "The server, or a proxy in front of it, could not answer (HTTP \(status))."
		case 300 ... 399: "The server address answers with a redirect (HTTP \(status)), which Native Note does not follow. Use the address the server itself answers on, or remove the redirect."
		default: "Invalid response from the server: HTTP \(status)."
		}
	}

	private static func describe(_ error: Error) -> String {
		switch error {
		case SyncError.refused(400), SyncError.unopenable: "The server did not accept this Mac's API key, or a proxy in front of it changed the request."
		case let SyncError.refused(status): statusMessage(status)
		case SyncError.serverFault: "The server could not store the changes. Its disk may be full."
		case SyncError.protocolViolation: "The server sent a reply Native Note does not understand."
		case let error as URLError: "The server could not be reached. \(error.localizedDescription)"
		default: Failure.reason(for: error)
		}
	}
}
