import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AppModelJoinTests {
	@Test func aJoinOpensTheServersBlobAndSyncsEveryNoteBothWays() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		try await fill(first, with: ["from the first Mac", "another"])
		let phrase = try await setUpSync(first, server)
		await first.syncNow()
		let (second, _) = try await syncingModel(server)
		try await fill(second, with: ["written before joining"])

		#expect(await second.prepareSync(server: server.url.absoluteString, apiKey: key) == .success(.existingLibrary))
		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(phrase.words)) == nil)
		await second.syncNow()
		await first.syncNow()

		let all: Set = ["from the first Mac", "another", "written before joining"]
		#expect(Set(second.notes.map(\.body)) == all)
		#expect(Set(first.notes.map(\.body)) == all)
		#expect(try await second.store?.syncSettings()?.contentKey == first.store?.syncSettings()?.contentKey)
		#expect(try await second.store?.pin() == 1)
		#expect(second.syncStatus.server == server.url.absoluteString)
	}

	@Test func aPhraseThatDoesNotOpenTheBlobStoresNothing() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		_ = try await setUpSync(first, server)
		let (second, _) = try await syncingModel(server)
		let other = try #require(Mnemonic.words(for: SymmetricKey(size: .bits256)))

		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(other)) == .phraseDoesNotOpen)
		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(Array(other.prefix(23)))) == .phraseDoesNotOpen)

		#expect(try await second.store?.syncSettings() == nil)
		#expect(second.syncStatus.phase == .off)
	}

	@Test func aJoinPinsTheServersVersionSoTheNewMacCanChangeThePhrase() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		_ = try await setUpSync(first, server)
		let rotated = try #require(await first.prepareRotation())
		#expect(await first.finishRotation(answers: answers(rotated)) == nil)
		let (second, _) = try await syncingModel(server)

		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(rotated.words)) == nil)
		#expect(try await second.store?.pin() == 2)
		let next = try #require(await second.prepareRotation())
		#expect(await second.finishRotation(answers: answers(next)) == nil)

		#expect(try await storedBlob(server).v == 3)
	}

	@Test func aLibraryThatAlreadyHoldsAContentKeyRefusesAJoin() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		let phrase = try await setUpSync(first, server)
		let held = try #require(try await first.store?.syncSettings())

		#expect(await first.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(phrase.words)) == .alreadySetUp)

		let store = try await openStore(at: temporaryDatabase())
		try await store.enableSync(held, pin: 1)
		let other = SyncSettings(server: held.server, apiKey: held.apiKey, contentKey: SymmetricKey(size: .bits256))
		await #expect(throws: NoteStore.SyncAlreadySetUp.self) { try await store.enableSync(other, pin: 4) }
		#expect(try await store.syncSettings()?.contentKey == held.contentKey)
		#expect(try await store.pin() == 1)
	}

	@Test func aJoinOfAServerWithNoLibraryAsksToStartOne() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (model, _) = try await syncingModel(server)
		let words = try #require(Mnemonic.words(for: SymmetricKey(size: .bits256)))

		#expect(await model.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(words)) == .serverHasNoLibrary)
		#expect(try await model.store?.syncSettings() == nil)
	}

	@Test func aJoinRefusesBadInputAndAWrongKeyAndStoresNothing() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		let phrase = try await setUpSync(first, server)
		let (second, _) = try await syncingModel(server)
		let words = entry(phrase.words)
		let url = server.url.absoluteString

		#expect(await second.joinSync(server: "notes.example", apiKey: key, phrase: words) == .invalidServer)
		#expect(await second.joinSync(server: url, apiKey: "abc", phrase: words) == .invalidAPIKey)
		#expect(await second.joinSync(server: url, apiKey: String(repeating: "0", count: 64), phrase: words) == .refused)

		#expect(try await second.store?.syncSettings() == nil)
	}

	@Test func aJoinWhoseReplyIsLostAsksAgainAndLands() async throws {
		let server = try SyncServer()
		let key = try apiKeyText(server)
		let (first, _) = try await syncingModel(server)
		let phrase = try await setUpSync(first, server)
		let (second, transport) = try await syncingModel(server)
		transport.failNext(.dropResponse)

		#expect(await second.joinSync(server: server.url.absoluteString, apiKey: key, phrase: entry(phrase.words)) == nil)
		#expect(try await second.store?.pin() == 1)
	}
}
