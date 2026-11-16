import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct AppModelSyncTests {
	@Test func settingUpPutsTheContentKeyUnderThePhraseAtVersionOneAndStartsSyncing() async throws {
		let server = try SyncServer()
		let (model, _) = try await syncingModel(server)
		let phrase = try newLibrary(await model.prepareSync(server: " \(server.url.absoluteString) ", apiKey: apiKeyText(server)))
		#expect(phrase.words.count == 24 && phrase.positionsToConfirm.count == 3 && Set(phrase.positionsToConfirm).count == 3)
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

	@Test func aStoredServerAddressThatCannotBeReadIsReportedNotTakenForSyncOff() async throws {
		let model = try await libraryWithUnreadableServerAddress()

		let reason = "The saved server address cannot be read. Enter the server again in Settings."
		#expect(model.phase == .unlocked)
		#expect(model.failure == .failed(reason, title: "Sync could not start."))
		#expect(await model.adoptCurrentPhrase(entry(["any", "words"])) == .failed(reason))
	}

	@Test func aPhraseChangeOnAServerAddressThatCannotBeReadSaysWhyWithoutAnAlert() async throws {
		let model = try await libraryWithUnreadableServerAddress()
		model.dismissFailure()

		#expect(await model.prepareRotation() == .failure(.failed("The saved server address cannot be read. Enter the server again in Settings.")))
		#expect(model.failure == nil)
	}

	@Test func aPhraseChangeWithoutSyncSaysSyncIsNotSetUp() async throws {
		let (model, _) = try await unlockedModel { .testing(in: $0) }

		#expect(await model.prepareRotation() == .failure(.notSetUp))
		#expect(model.failure == nil)
	}

	@Test func setupRefusesBadInputAndAWrongKeyAndJoinsAServerThatAlreadyHoldsALibrary() async throws {
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
		#expect(await second.prepareSync(server: server.url.absoluteString, apiKey: key) == .success(.existingLibrary))
	}

	@Test func aSetupPutWhoseResponseIsLostIsSentAgainUnchangedAndLands() async throws {
		let server = try SyncServer()
		let (model, transport) = try await syncingModel(server)
		let phrase = try newLibrary(await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)))
		transport.failNext(.dropResponse)

		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		#expect(try await storedBlob(server).v == 1)
	}

	@Test func aSetupAndAPhraseChangeThatAProxyFailsAfterForwardingStillLand() async throws {
		let server = try SyncServer()
		let (model, transport) = try await syncingModel(server)
		let phrase = try newLibrary(await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)))
		transport.failNext(.replyReplaced)
		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		#expect(try await model.store?.pin() == 1)

		let next = try await model.prepareRotation().get()
		transport.failNext(.replyReplaced)
		#expect(await model.finishRotation(answers: answers(next)) == nil)

		#expect(try await model.store?.pin() == 2)
		let stored = try await storedBlob(server)
		let nextKey = try #require(Mnemonic.key(from: next.words))
		#expect(stored.v == 2 && RecoveryBlob.open(stored.blob, under: nextKey) != nil)
	}

	@Test func twoMacsSettingUpAtOnceSendTheLaterOneToJoinTheFirst() async throws {
		let server = try SyncServer()
		let (first, _) = try await syncingModel(server)
		let (second, _) = try await syncingModel(server)
		let key = try apiKeyText(server)
		let firstPhrase = try newLibrary(await first.prepareSync(server: server.url.absoluteString, apiKey: key))
		let secondPhrase = try newLibrary(await second.prepareSync(server: server.url.absoluteString, apiKey: key))

		#expect(await first.finishSync(answers: answers(firstPhrase)) == nil)
		#expect(await second.finishSync(answers: answers(secondPhrase)) == .serverHasLibrary)
		#expect(second.syncStatus.phase == .off)
		#expect(try await second.store?.syncSettings() == nil)

		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(firstPhrase.words)) == nil)
		#expect(try await second.store?.syncSettings()?.contentKey == first.store?.syncSettings()?.contentKey)
	}

	@Test func rotationMovesThePinAndAStalePinAdoptsTheCurrentPhraseBeforeRotatingAgain() async throws {
		let server = try SyncServer()
		let (a, _) = try await syncingModel(server)
		_ = try await setUpSync(a, server)
		let (b, _) = try await syncingModel(server)
		let settings = try #require(try await a.store?.syncSettings())
		try await #require(b.store).enableSync(settings, pin: 1)

		let bPhrase = try await b.prepareRotation().get()
		#expect(await b.finishRotation(answers: answers(bPhrase)) == nil)
		#expect(try await b.store?.pin() == 2)
		let aPhrase = try await a.prepareRotation().get()
		#expect(await a.finishRotation(answers: answers(aPhrase)) == .rotatedElsewhere)

		#expect(await a.adoptCurrentPhrase(entry(aPhrase.words)) == .phraseDoesNotOpen)
		#expect(await a.adoptCurrentPhrase(entry(bPhrase.words)) == nil)
		#expect(try await a.store?.pin() == 2)
		var numbered = PhraseEntry()
		_ = numbered.set(bPhrase.words.enumerated().map { "\($0.offset + 1). \($0.element)," }.joined(separator: " "), at: 0)
		#expect(await a.adoptCurrentPhrase(numbered) == nil)
		let again = try await a.prepareRotation().get()
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
		await b.sync.start(try #require(b.store))

		try await fill(a, with: ["From A"])
		await a.syncNow()
		await b.syncNow()
		#expect(b.notes.map(\.body) == ["From A"])

		let id = try #require(b.notes.first?.id)
		b.edit(id, "Edited on B")
		try await settle { b.notes.first { $0.id == id }?.dirty == false }
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
		await b.sync.start(store)
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
