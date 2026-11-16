import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(2)))
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
		let next = try await owner.prepareRotation().get()
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
		#expect(owner.store == nil && owner.sync.engine == nil)
		#expect(owner.notes.isEmpty)
		#expect(owner.syncStatus == AppModel.SyncStatus())
	}

	@Test func aDeletedNoteLeavesNoPlaintextOnDisk() async throws {
		let (model, directory) = try await unlockedModel { AppModel.testing(in: $0) }
		try await fill(model, with: ["quartzite zephyr deleted", "kept"])
		await model.delete(try #require(model.notes.first { $0.body.hasPrefix("quartzite") }).id)

		await model.lock()

		for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
			#expect(try Data(contentsOf: file).range(of: Data("quartzite".utf8)) == nil, "\(file.lastPathComponent)")
		}
	}

	@Test func anyNumberOfWrongPasswordsLeavesTheRightOneWorking() async throws {
		let (model, _) = try await unlockedModel { AppModel.testing(in: $0, shakeTimer: { _ in }) }
		await model.lock()

		for attempt in 0 ..< 25 {
			await model.submit(password: "guess \(attempt)")
			#expect(model.failure == .wrongPassword)
		}
		await model.submit(password: workspacePassword)

		#expect(model.phase == .unlocked)
	}

	@Test func aLibraryWithoutHardwareBindingCanBeGuessedFromItsFilesAlone() async throws {
		let (model, directory) = try await unlockedModel { AppModel.testing(in: $0) }
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

	@Test func sqlCipherUsesCommonCryptoAndBothCLibrariesArePinned() async throws {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		let connection = try SQLiteConnection(url: url, rawKey: SymmetricKey(size: .bits256))
		#expect(try connection.scalar("PRAGMA cipher_provider") == "commoncrypto")
		#expect(try connection.scalar("PRAGMA cipher") == "aes-256-cbc")
		#expect(try connection.scalar("PRAGMA cipher_hmac_algorithm") == "HMAC_SHA512")

		let kit = repository.appending(path: "clients/macos/native-note-kit")
		let package = try String(contentsOf: kit.appending(path: "Package.swift"), encoding: .utf8)
		let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: kit.appending(path: "Package.resolved"))) as? [String: Any]
		let pins = try #require(resolved?["pins"] as? [[String: Any]])
		#expect(pins.compactMap { $0["identity"] as? String } == ["phc-winner-argon2"])
		let argon2 = try #require((pins.first?["state"] as? [String: Any])?["revision"] as? String)
		#expect(argon2.count == 40 && argon2.allSatisfy(\.isHexDigit))
		#expect(package.contains("revision: \"\(argon2)\""))

		let script = try String(contentsOf: kit.appending(path: "Scripts/sqlcipher-amalgamation.sh"), encoding: .utf8)
		func pinned(_ name: String, digits: Int) throws -> String {
			let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("\(name)=\"") })
			let value = String(line.dropFirst(name.count + 2).dropLast())
			#expect(value.count == digits && value.allSatisfy(\.isHexDigit), "\(name)")
			return value
		}
		#expect(try gitlink(of: "clients/macos/native-note-kit/sqlcipher") == (try pinned("commit", digits: 40)))
		for (name, path) in [("sqlite3_c_sha256", "sqlite3.c"), ("sqlite3_h_sha256", "include/sqlite3.h")] {
			let generated = try Data(contentsOf: kit.appending(path: "Sources/SQLCipher/\(path)"))
			#expect(SHA256.hash(data: generated).map { String(format: "%02x", $0) }.joined() == (try pinned(name, digits: 64)), "\(path)")
		}
	}

	@Test func thePackageTheAppLinksHoldsNoDevelopmentTool() throws {
		let kit = repository.appending(path: "clients/macos/native-note-kit")
		let package = try String(contentsOf: kit.appending(path: "Package.swift"), encoding: .utf8)
		let targets = try FileManager.default.contentsOfDirectory(at: kit.appending(path: "Sources"), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)

		#expect(!package.contains("executableTarget"))
		#expect(Set(targets.map(\.lastPathComponent)) == ["NativeNoteKit", "SQLCipher"])
	}

	private func gitlink(of path: String) throws -> String? {
		let git = Process()
		git.executableURL = URL(filePath: "/usr/bin/env")
		git.arguments = ["git", "ls-files", "--stage", "--", path]
		git.currentDirectoryURL = repository
		let output = Pipe()
		git.standardOutput = output
		try git.run()
		let entry = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(whereSeparator: \.isWhitespace)
		git.waitUntilExit()
		return entry.count == 4 && entry[0] == "160000" ? String(entry[1]) : nil
	}
}
