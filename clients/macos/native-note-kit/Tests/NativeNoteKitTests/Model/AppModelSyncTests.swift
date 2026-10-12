import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
private func syncingModel(_ server: SyncServer, alarm: Alarm? = nil, idle: Duration = .milliseconds(50)) async throws -> (AppModel, TestTransport) {
	let transport = TestTransport(server)
	let (model, _) = try await unlockedModel { directory in
		AppModel(
			directory: directory,
			scheduler: alarm.map { SaveScheduler(sleep: $0.sleep) } ?? SaveScheduler(),
			makeTransport: { _ in transport },
			syncDelay: idle
		)
	}
	return (model, transport)
}

@MainActor
private func apiKeyText(_ server: SyncServer) throws -> String {
	try String(contentsOf: server.data.appending(path: "api-key"), encoding: .utf8)
}

@MainActor
private func answers(_ phrase: AppModel.RecoveryPhrase) -> [String] {
	phrase.checked.map { phrase.words[$0] }
}

@MainActor
private func setUpSync(_ model: AppModel, _ server: SyncServer) async throws -> AppModel.RecoveryPhrase {
	let phrase = try await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)).get()
	try #require(await model.finishSync(answers: answers(phrase)) == nil)
	return phrase
}

@MainActor
private func storedBlob(_ server: SyncServer) async throws -> (v: UInt32, blob: Data) {
	let connection = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
	guard case let .get(v, blob) = try await connection.send(.get) else { throw SyncError.protocolViolation }
	return (v, blob)
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelSyncTests {
	@Test func settingUpPutsTheContentKeyUnderThePhraseAtVersionOneAndStartsSyncing() async throws {
		let server = try SyncServer()
		let (model, _) = try await syncingModel(server)
		let phrase = try await model.prepareSync(server: " \(server.url.absoluteString) ", apiKey: apiKeyText(server)).get()
		#expect(phrase.words.count == 24 && phrase.checked.count == 3 && Set(phrase.checked).count == 3)
		#expect(try await storedBlob(server).v == 0)

		#expect(await model.finishSync(answers: ["wrong", "words", "here"]) == .wordsDoNotMatch)
		#expect(await model.finishSync(answers: answers(phrase).map { " \($0.uppercased())" }) == nil)

		let stored = try await storedBlob(server)
		let recoveryKey = try #require(Mnemonic.key(from: phrase.words))
		#expect(stored.v == 1)
		#expect(RecoveryBlob.open(stored.blob, under: recoveryKey) != nil)
		#expect(model.syncStatus.server == server.url.absoluteString)
		#expect(model.syncStatus.phase != .off)
	}

	@Test func setupRefusesBadInputAWrongKeyAndAServerThatAlreadyHoldsALibrary() async throws {
		let server = try SyncServer()
		let (first, _) = try await syncingModel(server)
		let (second, _) = try await syncingModel(server)
		let key = try apiKeyText(server)
		#expect(await first.prepareSync(server: "notes.example", apiKey: key) == .failure(.invalidServer))
		#expect(await first.prepareSync(server: "ftp://notes.example/", apiKey: key) == .failure(.invalidServer))
		#expect(await first.prepareSync(server: server.url.absoluteString, apiKey: "abc") == .failure(.invalidAPIKey))
		let wrong = String(repeating: "0", count: 64)
		#expect(await first.prepareSync(server: server.url.absoluteString, apiKey: wrong) == .failure(.refused))

		_ = try await setUpSync(first, server)
		#expect(await second.prepareSync(server: server.url.absoluteString, apiKey: key) == .failure(.serverHasLibrary))
	}

	@Test func aSetupPutWhoseResponseIsLostIsSentAgainUnchangedAndLands() async throws {
		let server = try SyncServer()
		let (model, transport) = try await syncingModel(server)
		let phrase = try await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)).get()
		transport.failNext(.dropResponse)

		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		#expect(try await storedBlob(server).v == 1)
	}

	@Test func twoMacsSettingUpAtOnceSendTheLaterOneToRestore() async throws {
		let server = try SyncServer()
		let (first, _) = try await syncingModel(server)
		let (second, _) = try await syncingModel(server)
		let key = try apiKeyText(server)
		let firstPhrase = try await first.prepareSync(server: server.url.absoluteString, apiKey: key).get()
		let secondPhrase = try await second.prepareSync(server: server.url.absoluteString, apiKey: key).get()

		#expect(await first.finishSync(answers: answers(firstPhrase)) == nil)
		#expect(await second.finishSync(answers: answers(secondPhrase)) == .serverHasLibrary)
		#expect(second.syncStatus.phase == .off)
	}

	@Test func rotationMovesThePinAndAStalePinAdoptsTheCurrentPhraseBeforeRotatingAgain() async throws {
		let server = try SyncServer()
		let (a, _) = try await syncingModel(server)
		_ = try await setUpSync(a, server)
		let (b, _) = try await syncingModel(server)
		let settings = try #require(try await a.store?.syncSettings())
		try await #require(b.store).enableSync(settings, pin: 1)

		let bPhrase = try #require(await b.prepareRotation())
		#expect(await b.finishRotation(answers: answers(bPhrase)) == nil)
		#expect(try await b.store?.pin() == 2)
		let aPhrase = try #require(await a.prepareRotation())
		#expect(await a.finishRotation(answers: answers(aPhrase)) == .rotatedElsewhere)

		#expect(await a.adoptCurrentPhrase(aPhrase.words.joined(separator: " ")) == .phraseDoesNotOpen)
		#expect(await a.adoptCurrentPhrase(bPhrase.words.joined(separator: " ")) == nil)
		#expect(try await a.store?.pin() == 2)
		let again = try #require(await a.prepareRotation())
		#expect(await a.finishRotation(answers: answers(again)) == nil)
		let stored = try await storedBlob(server)
		#expect(stored.v == 3)
		#expect(RecoveryBlob.open(stored.blob, under: try #require(Mnemonic.key(from: again.words))) == settings.contentKey)
	}

	@Test func twoModelsSyncEditsBothWaysThroughSyncNowAndTheIdleTimer() async throws {
		let server = try SyncServer()
		let (a, _) = try await syncingModel(server)
		_ = try await setUpSync(a, server)
		let (b, _) = try await syncingModel(server)
		try await #require(b.store).enableSync(try #require(try await a.store?.syncSettings()), pin: 1)
		await b.startSync(try #require(b.store))

		try await fill(a, with: ["From A"])
		await a.syncNow()
		await b.syncNow()
		#expect(b.notes.map(\.body) == ["From A"])

		let id = try #require(b.notes.first?.id)
		b.edit(id, "Edited on B")
		try await Task.sleep(for: .milliseconds(600))
		await a.syncNow()
		#expect(a.notes.map(\.body) == ["Edited on B"])
		#expect(b.syncStatus.lastSynced != nil && b.syncStatus.problems.isEmpty)
	}

	@Test func aSaveLandingAfterAPullItDidNotSeeBecomesACopyThatTheEditorFollows() async throws {
		let alarm = Alarm()
		let server = try SyncServer()
		let (a, _) = try await syncingModel(server)
		_ = try await setUpSync(a, server)
		let settings = try #require(try await a.store?.syncSettings())
		let (b, transport) = try await syncingModel(server, alarm: alarm, idle: .seconds(3600))
		let store = try #require(b.store)
		try await store.enableSync(settings, pin: 1)
		await b.startSync(store)
		try await fill(a, with: ["shared"])
		await a.syncNow()
		await b.syncNow()
		let id = try #require(b.notes.first?.id)
		b.selection = id

		b.edit(id, "typed on B")
		a.edit(id, "edited on A")
		await a.syncNow()
		_ = try await SyncEngine(store: store, settings: settings, transport: transport).sync()
		await alarm.ring()
		await b.flushPendingSaves()

		let copy = try #require(b.selection)
		#expect(copy != id)
		#expect(b.notes.first { $0.id == id }?.body == "edited on A")
		#expect(b.notes.first { $0.id == copy }?.body == "typed on B")
		#expect(try await store.note(id: copy)?.body == "typed on B")
		await b.syncNow()
		await a.syncNow()
		#expect(Set(a.notes.map(\.body)) == ["edited on A", "typed on B"])
	}

	@Test func aKeystrokeHeldWhileAPullReplacesItsNoteMovesToTheCopyAndTheEditorFollows() async throws {
		let alarm = Alarm()
		let server = try SyncServer()
		let (model, _) = try await syncingModel(server, alarm: alarm)
		let store = try #require(model.store)
		try await fill(model, with: ["original"])
		let id = try #require(model.selection)
		model.edit(id, "original, typed on")
		#expect(model.scheduler.isPending(id))

		let remote = Note(id: id, body: "replaced elsewhere", createdAt: 1, updatedAt: 2, v: 4)
		await model.reconcile(Applied(changed: [id: remote], pulled: [id]), in: store)

		let copy = try #require(model.selection)
		#expect(copy != id)
		#expect(model.notes.first { $0.id == id }?.body == "replaced elsewhere")
		#expect(model.notes.first { $0.id == copy }?.body == "original, typed on")
		await model.flushPendingSaves()
		let saved = try #require(try await store.note(id: copy))
		#expect(saved.body == "original, typed on" && saved.dirty && saved.v == 0)
	}
}
