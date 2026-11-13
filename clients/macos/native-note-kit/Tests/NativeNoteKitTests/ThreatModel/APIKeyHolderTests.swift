import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(2)))
struct APIKeyHolderTests {
	private func attacker(_ server: SyncServer) throws -> SyncConnection {
		SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
	}

	@Test func anAPIKeyHolderCanDestroyTheRecoveryPathButCannotPlantAKey() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server)
		let phrase = try await setUpSync(owner, server)
		let held = try #require(try await owner.store?.syncSettings())
		let planted = try RecoveryBlob.seal(SymmetricKey(size: .bits256), under: SymmetricKey(size: .bits256))

		#expect(try await attacker(server).send(.put(v: 2, blob: planted)) == .put(status: .accepted, v: 2))

		let (newMac, _) = try await syncingModel(server)
		let key = try apiKeyText(server)
		#expect(await newMac.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(phrase.words)) == .phraseDoesNotOpen)
		#expect(try await newMac.store?.syncSettings() == nil)
		#expect(await owner.adoptCurrentPhrase(entry(phrase.words)) == .phraseDoesNotOpen)
		let next = try #require(await owner.prepareRotation())
		#expect(await owner.finishRotation(answers: answers(next)) == .rotatedElsewhere)
		#expect(try await owner.store?.syncSettings()?.contentKey == held.contentKey)
		#expect(try await owner.store?.pin() == 1)
	}

	@Test func aStolenAPIKeyForgesWritesTheServerKeepsButNoClientApplies() async throws {
		let server = try SyncServer()
		let (owner, transport) = try await syncingModel(server, idle: .seconds(3600))
		try await fill(owner, with: ["the real text"])
		_ = try await setUpSync(owner, server)
		await owner.syncNow()
		let attacker = try attacker(server)
		guard case let .sync(_, changes, _, _) = try await attacker.send(.sync(since: 0, writes: [])), let real = changes.first else {
			Issue.record("the attacker saw no note")
			return
		}

		let forged = [
			Write(blindedId: real.blindedId, v: real.v + 1, writeId: Data(count: 16), payload: Data(repeating: 7, count: Content.block + 28)),
			Write(blindedId: Data(repeating: 9, count: 16), v: 1, writeId: Data(count: 16), payload: Data(repeating: 7, count: Content.block + 28)),
		]
		guard case let .sync(results, _, _, _) = try await attacker.send(.sync(since: 0, writes: forged)) else {
			Issue.record("the forged push was not answered as a sync")
			return
		}
		#expect(results.map(\.status) == [.accepted, .accepted])

		let store = try #require(owner.store)
		let applied = try await SyncEngine(store: store, settings: try #require(try await store.syncSettings()), transport: transport).sync()
		#expect(applied.problems == [.unverifiableChange, .unverifiableChange])
		#expect(try await store.liveNotes().map(\.body) == ["the real text"])
	}

	@Test func replacingTheServersAPIKeyShutsOutEveryHolderOfTheOldOne() async throws {
		let server = try SyncServer()
		let (owner, _) = try await syncingModel(server, idle: .seconds(3600))
		_ = try await setUpSync(owner, server)
		await owner.syncNow()
		try #require(owner.syncStatus.phase == .idle)

		server.kill()
		let replacement = (0 ..< 32).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
		try Data((replacement + "\n").utf8).write(to: server.data.appending(path: "api-key"))
		try server.start()
		await owner.syncNow()

		guard case .failed = owner.syncStatus.phase else {
			Issue.record("the old key still syncs: \(owner.syncStatus.phase)")
			return
		}
		let replaced = SyncConnection(apiKey: try #require(EnvelopeKey.apiKey(fromHex: replacement)), transport: HTTPTransport(url: server.url))
		guard case let .get(v, _) = try await replaced.send(.get) else {
			Issue.record("the new key was not answered")
			return
		}
		#expect(v == 1)
	}
}
