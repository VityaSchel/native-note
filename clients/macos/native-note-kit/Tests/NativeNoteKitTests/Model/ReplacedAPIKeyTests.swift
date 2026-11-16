import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct ReplacedAPIKeyTests {
	private func syncingLibrary(_ server: SyncServer) async throws -> (AppModel, URL, TestTransport) {
		let transport = TestTransport(server)
		let (model, directory) = try await unlockedModel { AppModel.testing(in: $0, transport: transport) }
		_ = try await setUpSync(model, server)
		try await fill(model, with: ["before the key changed"])
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle)
		return (model, directory, transport)
	}

	private func replaceKey(of server: SyncServer, meanwhile: () throws -> Void = {}) throws -> String {
		server.kill()
		try meanwhile()
		let replacement = SymmetricKey(size: .bits256).withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
		try Data((replacement + "\n").utf8).write(to: server.data.appending(path: "api-key"))
		try server.start()
		return replacement
	}

	private func changeServer(_ model: AppModel, _ server: SyncServer, key: String) async -> Result<AppModel.SyncSetupStart, AppModel.SyncSetupFailure> {
		await model.prepareSync(server: server.url.absoluteString, apiKey: key)
	}

	private func storedKey(_ model: AppModel) async throws -> Data {
		try #require(try await model.store?.syncSettings()).apiKey.withUnsafeBytes { Data($0) }
	}

	private func serverFiles(_ server: SyncServer) throws -> [URL] {
		try FileManager.default.contentsOfDirectory(at: server.data, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("native-note.sqlite") }
	}

	@Test func aMacTakesTheServersNewKeyThroughChangeServerAndKeepsItAcrossARelaunch() async throws {
		let server = try SyncServer()
		let (model, directory, transport) = try await syncingLibrary(server)
		let replacement = try replaceKey(of: server)
		model.edit(try #require(model.selection), "typed while shut out")
		await model.syncNow()
		guard case .failed = model.syncStatus.phase else {
			Issue.record("the old key still syncs: \(model.syncStatus.phase)")
			return
		}

		#expect(await changeServer(model, server, key: " \(replacement)\n") == .success(.reattached))
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(try await model.store?.liveNotes().allSatisfy { !$0.dirty } == true)
		#expect(try await storedKey(model) == Data(try #require(EnvelopeKey.apiKey(fromHex: replacement)).withUnsafeBytes { Data($0) }))
		await model.lock()

		let relaunched = AppModel.testing(in: directory, transport: transport)
		relaunched.start()
		await relaunched.unlock(password: workspacePassword)
		await relaunched.syncNow()
		#expect(relaunched.syncStatus.phase == .idle)
		#expect(relaunched.notes.map(\.body) == ["typed while shut out"])
	}

	@Test func aKeyTheServerRefusesLeavesTheOldOneSyncing() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let held = try await storedKey(model)

		#expect(await changeServer(model, server, key: String(repeating: "ab", count: 32)) == .failure(.refused))
		#expect(await changeServer(model, server, key: "not a key") == .failure(.invalidAPIKey))

		#expect(try await storedKey(model) == held)
		model.edit(try #require(model.selection), "still syncing")
		await model.syncNow()
		#expect(model.syncStatus.phase == .idle)
	}

	@Test func aServerThatLostTheLibraryOffersToMoveItThereAndKeepsTheOldKeyMeanwhile() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server) {
			for file in try serverFiles(server) { try FileManager.default.removeItem(at: file) }
		}

		guard case .success(.newLibrary) = await changeServer(model, server, key: replacement) else {
			Issue.record("an empty server was not offered the library")
			return
		}
		#expect(try await storedKey(model) == held)
		model.cancelRecovery()
		#expect(try await storedKey(model) == held)
	}

	@Test func aServerHoldingAnotherLibraryKeepsTheOldKey() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server) {
			for file in try serverFiles(server) { try FileManager.default.removeItem(at: file) }
		}
		let (other, _) = try await unlockedModel { AppModel.testing(in: $0, transport: TestTransport(server)) }
		_ = try await setUpSync(other, server)
		try await fill(other, with: ["another library", "and its second note"])
		await other.syncNow()
		try #require(other.syncStatus.phase == .idle)
		try #require(try await storedBlob(server).v == 1)

		#expect(await changeServer(model, server, key: replacement) == .failure(.serverHoldsAnotherLibrary))
		#expect(try await storedKey(model) == held)
	}

	@Test func aServerRestoredFromBeforeThePhraseChangedKeepsTheOldKey() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let backup = temporaryDirectory()
		try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
		server.kill()
		for file in try serverFiles(server) { try FileManager.default.copyItem(at: file, to: backup.appending(path: file.lastPathComponent)) }
		try server.start()
		let next = try await model.prepareRotation().get()
		try #require(await model.finishRotation(answers: answers(next)) == nil)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server) {
			for file in try serverFiles(server) { try FileManager.default.removeItem(at: file) }
			for file in try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
				try FileManager.default.copyItem(at: file, to: server.data.appending(path: file.lastPathComponent))
			}
		}
		try #require(try await storedBlob(server).v == 1)

		#expect(await changeServer(model, server, key: replacement) == .failure(.serverBehind))
		#expect(try await storedKey(model) == held)
	}

	@Test func aServerRestoredFromBeforeTheLastPullKeepsTheOldKey() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let backup = temporaryDirectory()
		try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
		server.kill()
		for file in try serverFiles(server) { try FileManager.default.copyItem(at: file, to: backup.appending(path: file.lastPathComponent)) }
		try server.start()
		try await fill(model, with: ["after the backup"])
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server) {
			for file in try serverFiles(server) { try FileManager.default.removeItem(at: file) }
			for file in try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
				try FileManager.default.copyItem(at: file, to: server.data.appending(path: file.lastPathComponent))
			}
		}

		#expect(await changeServer(model, server, key: replacement) == .failure(.serverHoldsAnotherLibrary))
		#expect(try await storedKey(model) == held)
	}

	@Test func aWriteForgedWithTheLeakedKeyAtTheLastSeqDoesNotBlockTheNewKey() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let leaked = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		let junk = Write(blindedId: Data(repeating: 9, count: 16), v: 1, writeId: Data(count: 16), payload: Data(repeating: 7, count: Content.block + 28))
		guard case let .sync(results, _, _, _) = try await leaked.send(.sync(since: 0, writes: [junk])), results.first?.status == .accepted else {
			Issue.record("the server did not keep the forged write")
			return
		}
		await model.syncNow()
		try #require(try await model.store?.lastPulled() == PullMark(blindedId: junk.blindedId, v: 1))
		let replacement = try replaceKey(of: server)

		#expect(await changeServer(model, server, key: replacement) == .success(.reattached))
		await model.syncNow()
		#expect(model.syncStatus.phase == .idle)
	}

	@Test func anEmptyRecoveryBlobPutWithTheLeakedKeyDoesNotBlockTheNewKey() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingLibrary(server)
		let leaked = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		let pin = try #require(try await model.store?.pin())
		guard case .put(.accepted, _) = try await leaked.send(.put(v: pin + 1, blob: Data())) else {
			Issue.record("the server did not keep the empty blob")
			return
		}
		let replacement = try replaceKey(of: server)

		#expect(await changeServer(model, server, key: replacement) == .success(.reattached))
		await model.syncNow()
		#expect(model.syncStatus.phase == .idle)
	}

	@Test func lockingCancelsAServerChangeInFlightAndKeepsTheOldKey() async throws {
		let server = try SyncServer()
		let stalling = Stalling(TestTransport(server))
		let (model, _) = try await unlockedModel { AppModel.testing(in: $0, transport: stalling) }
		_ = try await setUpSync(model, server)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server)
		stalling.stalls = true

		let changing = Task { await changeServer(model, server, key: replacement) }
		try await settle { stalling.stalled > 0 }
		try #require(stalling.stalled > 0)
		let started = ContinuousClock.now
		await model.lock()

		#expect(ContinuousClock.now - started < .seconds(10))
		#expect(model.sync.serverChange == nil)
		#expect(await changing.value != .success(.reattached))
		stalling.stalls = false
		await model.unlock(password: workspacePassword)
		#expect(try await storedKey(model) == held)
	}

	@Test func cancellingAServerChangeInFlightKeepsTheOldKey() async throws {
		let server = try SyncServer()
		let stalling = Stalling(TestTransport(server))
		let (model, _) = try await unlockedModel { AppModel.testing(in: $0, transport: stalling) }
		_ = try await setUpSync(model, server)
		let held = try await storedKey(model)
		let replacement = try replaceKey(of: server)
		stalling.stalls = true

		let changing = Task { await changeServer(model, server, key: replacement) }
		try await settle { stalling.stalled > 0 }
		try #require(stalling.stalled > 0)
		changing.cancel()

		#expect(await changing.value != .success(.reattached))
		#expect(model.sync.serverChange == nil)
		stalling.stalls = false
		#expect(try await storedKey(model) == held)
		await model.lock()
	}
}

private final class Stalling: SyncTransport, @unchecked Sendable {
	private let real: TestTransport
	private let lock = NSLock()
	private var stalling = false
	private var count = 0

	init(_ real: TestTransport) {
		self.real = real
	}

	var stalls: Bool {
		get { lock.withLock { stalling } }
		set { lock.withLock { stalling = newValue } }
	}

	var stalled: Int {
		lock.withLock { count }
	}

	func post(_ body: Data) async throws -> Data {
		if stalls {
			lock.withLock { count += 1 }
			try await Task.sleep(for: .seconds(600))
		}
		return try await real.post(body)
	}
}
