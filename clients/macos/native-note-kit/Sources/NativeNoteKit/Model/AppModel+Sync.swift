import Foundation

extension AppModel: SyncedLibrary {
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

	public struct RecoveryPhrase: Equatable {
		public let words: [String]
		public let positionsToConfirm: [Int]
	}

	public enum SyncSetupStart: Equatable {
		case newLibrary(RecoveryPhrase)
		case existingLibrary
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
		case alreadySetUp
		case rotatedElsewhere
		case serverBehind
		case outcomeUnknown
		case wordsDoNotMatch
		case phraseDoesNotOpen
		case failed(String)

		static let wordlistMissing = Self.failed("The recovery wordlist is missing.")
		public static let notSetUp = Self.failed("Sync is not set up on this Mac.")
		static let rotationInterrupted = Self.failed("Start changing the phrase again.")

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

	public var syncStatus: SyncStatus {
		sync.status
	}

	public func syncNow() async {
		await sync.now()
	}

	public func prepareSync(server: String, apiKey: String) async -> Result<SyncSetupStart, SyncSetupFailure> {
		await sync.prepare(server: server, apiKey: apiKey)
	}

	public func joinSync(server: String, apiKey: String, phrase: PhraseEntry) async -> SyncSetupFailure? {
		await sync.join(server: server, apiKey: apiKey, phrase: phrase)
	}

	public func finishSync(answers: [String]) async -> SyncSetupFailure? {
		await sync.finish(answers: answers)
	}

	public func prepareRotation() async -> Result<RecoveryPhrase, SyncSetupFailure> {
		await sync.prepareRotation()
	}

	public func finishRotation(answers: [String]) async -> SyncSetupFailure? {
		await sync.finishRotation(answers: answers)
	}

	public func adoptCurrentPhrase(_ phrase: PhraseEntry) async -> SyncSetupFailure? {
		await sync.adoptCurrentPhrase(phrase)
	}

	public func cancelRecovery() {
		sync.cancelRecovery()
	}

	public func turnOffSync() async -> Failure? {
		guard let store else { return .unexpected("Unlock Native Note to turn off sync.") }
		await sync.stop()?.value
		do {
			try await store.disconnectSync()
			return nil
		} catch {
			await sync.start(store)
			return Failure(error, as: "Sync could not be turned off.")
		}
	}

	func commit(_ commit: Commit, to store: NoteStore) async throws -> Applied {
		scheduler.hold()
		defer { scheduler.release() }
		await scheduler.flushAll()
		let applied = try await store.commit(commit)
		await reconcile(applied, in: store)
		return applied
	}

	func reconcile(_ applied: Applied, in store: NoteStore) async {
		guard store === self.store else { return }
		let copies = Set(applied.copies.values)
		for (id, row) in applied.changed {
			if scheduler.isPending(id), applied.pulled.contains(id) {
				moveEdit(of: id, to: applied.copies[id] ?? UUID(), in: store)
			} else if scheduler.isPending(id), let index = notes.firstIndex(where: { $0.id == id }) {
				notes[index].v = row.v
				continue
			}
			let onlyAcknowledged = !applied.pulled.contains(id) && !copies.contains(id)
			if onlyAcknowledged, !notes.contains(where: { $0.id == id }) { continue }
			show(row)
		}
		for (original, copy) in applied.copies where selection == original {
			selection = copy
		}
	}

	func saveBecameCopy(_ note: Note, copy: UUID, in store: NoteStore) async {
		guard store === self.store else { return }
		if notes.contains(where: { $0.id == note.id }) {
			moveEdit(of: note.id, to: copy, in: store)
		} else {
			show(note.unsyncedCopy(id: copy))
		}
		do {
			if let original = try await store.note(id: note.id) { show(original) }
		} catch {
			if store === self.store { report(error, as: "The note could not be read.") }
		}
	}

	private func moveEdit(of id: UUID, to copyID: UUID, in store: NoteStore) {
		guard let edit = notes.first(where: { $0.id == id })?.unsyncedCopy(id: copyID) else { return }
		scheduler.cancel(id)
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

	nonisolated static func statusMessage(_ status: Int) -> String {
		switch status {
		case 413: "The server or a proxy in front of it refused a request this large. A proxy must accept request bodies of at least 2 MiB + 28 B, such as 3 MiB."
		case 500 ... 599: "The server, or a proxy in front of it, could not answer (HTTP \(status))."
		case 300 ... 399: "The server address answers with a redirect (HTTP \(status)), which Native Note does not follow. Use the address the server itself answers on, or remove the redirect."
		default: "Invalid response from the server: HTTP \(status)."
		}
	}
}
