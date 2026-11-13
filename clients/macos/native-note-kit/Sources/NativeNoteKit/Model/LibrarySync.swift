import CryptoKit
import Foundation
import Observation

protocol SyncedLibrary: AnyObject {
	var store: NoteStore? { get }
	func commit(_ commit: Commit, to store: NoteStore) async throws -> Applied
	func report(_ error: Error, as title: String)
}

@Observable final class LibrarySync {
	typealias Status = AppModel.SyncStatus
	typealias RecoveryPhrase = AppModel.RecoveryPhrase
	typealias SetupStart = AppModel.SyncSetupStart
	typealias SetupFailure = AppModel.SyncSetupFailure

	private struct RecoverySession {
		let settings: SyncSettings
		let recoveryKey: SymmetricKey
		let phrase: RecoveryPhrase
		var movesToEmptyServer = false
	}

	var status = Status()
	private(set) var engine: SyncEngine?
	private(set) var syncLoop: Task<Void, Never>?
	private(set) var serverChange: Task<Result<SetupStart, SetupFailure>, Never>?
	@ObservationIgnored weak var library: (any SyncedLibrary)?

	private let scheduler: SaveScheduler
	private let makeTransport: @Sendable (URL) -> any SyncTransport
	private let syncDelay: Duration
	private var idleSync: Task<Void, Never>?
	private var syncRequests = 0
	private var syncedThrough = 0
	private var recovery: RecoverySession?

	private var store: NoteStore? {
		library?.store
	}

	init(scheduler: SaveScheduler, makeTransport: @escaping @Sendable (URL) -> any SyncTransport, syncDelay: Duration) {
		self.scheduler = scheduler
		self.makeTransport = makeTransport
		self.syncDelay = syncDelay
	}

	func now() async {
		syncRequests += 1
		let wanted = syncRequests
		if syncLoop == nil {
			syncLoop = Task {
				while syncedThrough < syncRequests, !Task.isCancelled {
					let covered = syncRequests
					await once()
					syncedThrough = covered
				}
				syncLoop = nil
			}
		}
		while syncedThrough < wanted, let syncLoop {
			await syncLoop.value
		}
	}

	private func once() async {
		guard let engine, let library, let store = library.store else { return }
		idleSync?.cancel()
		status.phase = .syncing
		await scheduler.flushAll()
		do {
			let applied = try await engine.sync { try await library.commit($0, to: store) }
			guard store === self.store else { return }
			status.problems = applied.problems.map(Self.describe)
			status.lastSynced = Date()
			status.phase = .idle
		} catch {
			guard store === self.store else { return }
			status.phase = .failed(Self.describe(error))
		}
	}

	func soon() {
		guard engine != nil else { return }
		idleSync?.cancel()
		idleSync = Task { [syncDelay] in
			try? await Task.sleep(for: syncDelay)
			guard !Task.isCancelled else { return }
			idleSync = nil
			await now()
		}
	}

	func start(_ store: NoteStore) async {
		let settings: SyncSettings?
		do {
			settings = try await store.syncSettings()
		} catch {
			if store === self.store { library?.report(error, as: "Sync could not start.") }
			return
		}
		guard let settings, store === self.store else { return }
		engine = SyncEngine(store: store, settings: settings, transport: makeTransport(settings.server))
		status = Status(phase: .idle, server: settings.server.absoluteString)
		Task { await now() }
	}

	@discardableResult
	func stop() -> Task<Void, Never>? {
		let loop = syncLoop
		let change = serverChange
		loop?.cancel()
		change?.cancel()
		serverChange = nil
		idleSync?.cancel()
		idleSync = nil
		engine = nil
		recovery = nil
		status = Status()
		guard loop != nil || change != nil else { return nil }
		return Task {
			await loop?.value
			_ = await change?.value
		}
	}

	func prepare(server: String, apiKey: String) async -> Result<SetupStart, SetupFailure> {
		do {
			let endpoint = try Self.endpoint(server: server, apiKey: apiKey)
			if let store, let kept = try await store.keptLibrary() {
				return await changeServer(kept, to: endpoint.server, apiKey: endpoint.apiKey, in: store)
			}
			let settings = SyncSettings(server: endpoint.server, apiKey: endpoint.apiKey, contentKey: SymmetricKey(size: .bits256))
			guard try await flow(settings).storedVersion() == 0 else { return .success(.existingLibrary) }
			return newPhrase(for: settings).map { .success(.newLibrary($0)) } ?? .failure(.wordlistMissing)
		} catch {
			return .failure(Self.setupFailure(error))
		}
	}

	func join(server: String, apiKey: String, phrase: PhraseEntry) async -> SetupFailure? {
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
		await start(store)
		return nil
	}

	func finish(answers: [String]) async -> SetupFailure? {
		guard let store, let session = recovery, engine == nil || session.movesToEmptyServer else { return .failed("Start setting up sync again.") }
		guard Self.matches(answers, session.phrase) else { return .wordsDoNotMatch }
		do {
			let pin = try await flow(session.settings).put(session.settings.contentKey, under: session.recoveryKey, pin: 0)
			if session.movesToEmptyServer {
				await stop()?.value
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
		await start(store)
		return nil
	}

	func prepareRotation() async -> RecoveryPhrase? {
		guard let store else { return nil }
		do {
			return try await store.syncSettings().flatMap(newPhrase)
		} catch {
			if store === self.store { library?.report(error, as: "The recovery phrase could not be changed.") }
			return nil
		}
	}

	func finishRotation(answers: [String]) async -> SetupFailure? {
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

	func adoptCurrentPhrase(_ phrase: PhraseEntry) async -> SetupFailure? {
		guard let store else { return .failed("Sync is not set up.") }
		do {
			guard let settings = try await store.syncSettings() else { return .failed("Sync is not set up.") }
			guard let recoveryKey = phrase.key else { return .phraseDoesNotOpen }
			guard let pin = try await flow(settings).pin(opening: settings.contentKey, under: recoveryKey) else { return .phraseDoesNotOpen }
			try await store.setPin(pin)
		} catch {
			return Self.setupFailure(error)
		}
		return nil
	}

	func cancelRecovery() {
		recovery = nil
	}

	private func changeServer(_ kept: NoteStore.KeptLibrary, to server: URL, apiKey: SymmetricKey, in store: NoteStore) async -> Result<SetupStart, SetupFailure> {
		let change = Task { await self.reattachOrMove(kept, to: server, apiKey: apiKey, in: store) }
		serverChange = change
		let result = await withTaskCancellationHandler { await change.value } onCancel: { change.cancel() }
		guard serverChange == change else { return result }
		serverChange = nil
		guard result == .success(.reattached), store === self.store else { return result }
		await stop()?.value
		await start(store)
		return result
	}

	private func reattachOrMove(_ kept: NoteStore.KeptLibrary, to server: URL, apiKey: SymmetricKey, in store: NoteStore) async -> Result<SetupStart, SetupFailure> {
		do {
			let connection = SyncConnection(apiKey: apiKey, transport: makeTransport(server))
			let stored = try await RecoveryFlow(connection: connection).storedVersion()
			guard stored > 0 else {
				let settings = SyncSettings(server: server, apiKey: apiKey, contentKey: kept.contentKey)
				guard let phrase = newPhrase(for: settings) else { return .failure(.wordlistMissing) }
				recovery?.movesToEmptyServer = true
				return .success(.newLibrary(phrase))
			}
			guard stored >= kept.pin else { return .failure(.serverBehind) }
			if let mark = kept.mark, try await !SyncEngine.holds(mark, through: connection, since: kept.since) {
				return .failure(.serverHoldsAnotherLibrary)
			}
			try Task.checkCancellation()
			try await store.reattachSync(server: server, apiKey: apiKey)
			return .success(.reattached)
		} catch {
			return .failure(Self.setupFailure(error))
		}
	}

	private func newPhrase(for settings: SyncSettings) -> RecoveryPhrase? {
		let recoveryKey = SymmetricKey(size: .bits256)
		guard let words = Mnemonic.words(for: recoveryKey) else { return nil }
		let phrase = RecoveryPhrase(words: words, positionsToConfirm: Array(words.indices.shuffled().prefix(3)).sorted())
		recovery = RecoverySession(settings: settings, recoveryKey: recoveryKey, phrase: phrase)
		return phrase
	}

	private func flow(_ settings: SyncSettings) -> RecoveryFlow {
		flow(settings.server, settings.apiKey)
	}

	private func flow(_ server: URL, _ apiKey: SymmetricKey) -> RecoveryFlow {
		RecoveryFlow(connection: SyncConnection(apiKey: apiKey, transport: makeTransport(server)))
	}

	private static func matches(_ answers: [String], _ phrase: RecoveryPhrase) -> Bool {
		answers.count == phrase.positionsToConfirm.count
			&& zip(answers, phrase.positionsToConfirm).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == phrase.words[$1] }
	}

	private static func endpoint(server: String, apiKey: String) throws(SetupFailure) -> (server: URL, apiKey: SymmetricKey) {
		guard let url = SyncSettings.server(from: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw .invalidServer }
		guard let apiKey = EnvelopeKey.apiKey(fromHex: apiKey) else { throw .invalidAPIKey }
		return (url, apiKey)
	}

	private static func setupFailure(_ error: Error) -> SetupFailure {
		switch error {
		case let failure as SetupFailure: failure
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

	private static func describe(_ error: Error) -> String {
		switch error {
		case SyncError.refused(400), SyncError.unopenable: "The server did not accept this Mac's API key, or a proxy in front of it changed the request."
		case let SyncError.refused(status): AppModel.statusMessage(status)
		case SyncError.serverFault: "The server could not store the changes. Its disk may be full."
		case SyncError.protocolViolation: "The server sent a reply Native Note does not understand."
		case let error as URLError: "The server could not be reached. \(error.localizedDescription)"
		default: AppModel.Failure.reason(for: error)
		}
	}
}
