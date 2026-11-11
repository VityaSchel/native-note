import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

/// The out-of-scope items and documented risks of docs/ARCHITECTURE.md § Threat model hold exactly where they are drawn.
@MainActor @Suite(.timeLimit(.minutes(2)))
struct BoundaryTests {
	private let repository = URL(filePath: #filePath).appending(path: "../../../../../../..").standardized

	@Test func aServerWithholdingAChangeGoesUnnoticed() async throws {
		let store = try await openStore(at: temporaryDatabase())
		let cipher = NoteCipher(contentKey: sharedContentKey)
		let kept = try cipher.seal(.note(id: UUID(), createdAt: 1, updatedAt: 2, body: "sent"), v: 1)
		_ = try cipher.seal(.note(id: UUID(), createdAt: 1, updatedAt: 2, body: "withheld"), v: 1)
		let server = ScriptedServer()
		server.answer { _ in .sync(results: [], changes: [kept], nextSeq: 2, more: false) }

		let applied = try await server.device(store).sync()

		#expect(applied.problems.isEmpty)
		#expect(try await store.liveNotes().map(\.body) == ["sent"])
	}

	@Test func theContentAndAPIKeysAloneReadEveryNote() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server, idle: .seconds(3600))
		try await fill(owner, with: ["first", "second", "third"])
		_ = try await setUpSync(owner, server)
		await owner.syncNow()
		let stolen = try #require(try await owner.store?.syncSettings())

		let store = try await openStore(at: temporaryDatabase())
		try await store.enableSync(stolen, pin: 1)
		_ = try await SyncEngine(store: store, settings: stolen, transport: HTTPTransport(url: server.url)).sync()

		#expect(Set(try await store.liveNotes().map(\.body)) == ["first", "second", "third"])
	}

	@Test func withoutThePhraseOrADeviceTheServersNotesStaySealed() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server, idle: .seconds(3600))
		try await fill(owner, with: ["kept only here and in the phrase"])
		_ = try await setUpSync(owner, server)
		await owner.syncNow()
		let holder = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))

		guard case let .sync(_, changes, _, _) = try await holder.send(.sync(since: 0, writes: [])),
			case let .get(_, blob) = try await holder.send(.get)
		else {
			Issue.record("the server did not answer")
			return
		}
		#expect(!changes.isEmpty && changes.allSatisfy { NoteCipher(contentKey: SymmetricKey(size: .bits256)).open($0) == nil })
		#expect(RecoveryBlob.open(blob, under: SymmetricKey(size: .bits256)) == nil)
		let (stranger, _) = try await syncingModel(server)
		let guess = try #require(Mnemonic.words(for: SymmetricKey(size: .bits256)))
		let key = try apiKeyText(server)
		#expect(await stranger.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(guess)) == .phraseDoesNotOpen)
	}

	@Test func aBlobFromBeforeAPhraseChangeStillOpensWithTheOldWords() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server, idle: .seconds(3600))
		let old = try await setUpSync(owner, server)
		let held = try #require(try await owner.store?.syncSettings())
		let backup = try await storedBlob(server)
		let next = try #require(await owner.prepareRotation())
		try #require(await owner.finishRotation(answers: answers(next)) == nil)

		let oldKey = try #require(Mnemonic.key(from: old.words))
		#expect(RecoveryBlob.open(try await storedBlob(server).blob, under: oldKey) == nil)
		#expect(RecoveryBlob.open(backup.blob, under: oldKey) == held.contentKey)
	}

	@Test func lockingDropsWhatTheUnlockedLibraryHeld() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server, idle: .seconds(3600))
		try await fill(owner, with: ["while unlocked"])
		_ = try await setUpSync(owner, server)
		#expect(try await owner.store?.syncSettings() != nil)

		await owner.lock()

		#expect(owner.phase == .locked)
		#expect(owner.store == nil && owner.engine == nil)
		#expect(owner.notes.isEmpty)
		#expect(owner.syncStatus == AppModel.SyncStatus())
	}

	@Test func aDeletedNoteLeavesNoPlaintextOnDisk() async throws {
		let (model, directory) = try await unlockedModel { AppModel(directory: $0) }
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["quartzite zephyr deleted", "kept"])
		await model.delete(try #require(model.notes.first { $0.body.hasPrefix("quartzite") }).id)

		await model.lock()

		for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
			#expect(try Data(contentsOf: file).range(of: Data("quartzite".utf8)) == nil, "\(file.lastPathComponent)")
		}
	}

	@Test func anyNumberOfWrongPasswordsLeavesTheRightOneWorking() async throws {
		let (model, directory) = try await unlockedModel { AppModel(directory: $0, shakeTimer: { _ in }) }
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		for attempt in 0 ..< 25 {
			await model.submit(password: "guess \(attempt)")
			#expect(model.failure == .wrongPassword)
		}
		await model.submit(password: workspacePassword)

		#expect(model.phase == .unlocked)
	}

	@Test func aLibraryWithoutHardwareBindingCanBeGuessedFromItsFilesAlone() async throws {
		let (model, directory) = try await unlockedModel { AppModel(directory: $0) }
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["guessable"])
		await model.lock()
		let parameters = try AppLock.read(from: AppLock.currentFile(in: directory))
		#expect(parameters.enclaveKey == nil)

		let database = AppLock.databaseFile(in: directory)
		let found = try await Task.detached {
			try ["123456", "password", "letmein", workspacePassword, "qwerty"].first { guess in
				let key = try Unlock.localDbKey(password: guess, parameters: parameters)
				return (try? SQLiteConnection(url: database, rawKey: key, create: false).scalar("SELECT count(*) FROM note")) == "1"
			}
		}.value

		#expect(found == workspacePassword)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func withTheMachineIdReadOnceGuessingCostsOnlyArgon2() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try UnlockParameters.fastBoundToThisMac()
		let representation = try #require(parameters.enclaveKey)
		try AppLock.write(parameters, to: AppLock.currentFile(in: directory))
		let database = AppLock.databaseFile(in: directory)
		let key = try await Task.detached { try Unlock.localDbKey(password: workspacePassword, parameters: parameters) }.value
		try await NoteStore.create(url: database, key: key).close()

		let found = try await Task.detached {
			let machineId = try MachineKey(representation: representation).machineId()
			return try ["123456", "password", workspacePassword, "qwerty"].first { guess in
				let argon = try Argon2.hash(password: guess, salt: parameters.localSalt, parameters: parameters.argon)
				let key = KeyDerivation.localDbKey(argonOut: argon, machineId: machineId, localSalt: parameters.localSalt)
				return (try? SQLiteConnection(url: database, rawKey: key, create: false).scalar("SELECT count(*) FROM note")) != nil
			}
		}.value

		#expect(found == workspacePassword)
	}

	@Test func sqlCipherUsesCommonCryptoAndBothCLibrariesArePinnedToCommits() async throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: SymmetricKey(size: .bits256))
		#expect(try connection.scalar("PRAGMA cipher_provider") == "commoncrypto")
		#expect(try connection.scalar("PRAGMA cipher") == "aes-256-cbc")
		#expect(try connection.scalar("PRAGMA cipher_hmac_algorithm") == "HMAC_SHA512")

		let package = try String(contentsOf: repository.appending(path: "clients/macos/native-note-kit/Package.swift"), encoding: .utf8)
		let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: repository.appending(path: "clients/macos/native-note-kit/Package.resolved"))) as? [String: Any]
		let pins = try #require(resolved?["pins"] as? [[String: Any]])
		for identity in ["phc-winner-argon2", "sqlcipher.swift"] {
			let pin = try #require(pins.first { $0["identity"] as? String == identity })
			let revision = try #require((pin["state"] as? [String: Any])?["revision"] as? String)
			#expect(revision.count == 40 && revision.allSatisfy(\.isHexDigit), "\(identity)")
			#expect(package.contains("revision: \"\(revision)\""), "\(identity)")
		}
	}
}
