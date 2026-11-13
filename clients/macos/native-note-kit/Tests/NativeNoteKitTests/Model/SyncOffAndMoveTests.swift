import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct SyncOffAndMoveTests {
	private func mac() async throws -> (AppModel, URL) {
		try await unlockedModel { AppModel(directory: $0, makeTransport: { HTTPTransport(url: $0) }, syncDelay: .seconds(3600)) }
	}

	private func syncingMac(_ server: SyncServer, notes: [String]) async throws -> (AppModel, URL, AppModel.RecoveryPhrase) {
		let (model, directory) = try await mac()
		try await fill(model, with: notes)
		let phrase = try await setUpSync(model, server)
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle)
		return (model, directory, phrase)
	}

	private func bodiesOn(_ server: SyncServer) async throws -> Int {
		let connection = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		guard case let .sync(_, changes, _, _) = try await connection.send(.sync(since: 0, writes: [])) else { throw SyncError.protocolViolation }
		return changes.count
	}

	@Test func turningSyncOffKeepsTheNotesAndStopsSyncing() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingMac(server, notes: ["kept", "also kept"])

		#expect(await model.turnOffSync())

		#expect(model.syncStatus.server == nil && model.syncStatus.phase == .off)
		#expect(Set(model.notes.map(\.body)) == ["kept", "also kept"])
		model.edit(try #require(model.selection), "edited while off")
		await model.syncNow()
		#expect(try await bodiesOn(server) == 2)
		#expect(try await model.store?.syncSettings() == nil)
		#expect(try await model.store?.keptLibrary() != nil)
	}

	@Test func settingUpAgainOnTheSameServerReattachesWithoutWordsAndSendsWhatChanged() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingMac(server, notes: ["first"])
		let pin = try await model.store?.pin()
		#expect(await model.turnOffSync())
		try await fill(model, with: ["written while off"])

		#expect(await model.prepareSync(server: server.url.absoluteString, apiKey: try apiKeyText(server)) == .success(.reattached))
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(try await bodiesOn(server) == 2)
		#expect(try await model.store?.pin() == pin)
	}

	@Test func settingUpOnAnEmptyServerMovesTheLibraryUnderANewPhraseAndAnotherMacJoinsIt() async throws {
		let old = try SyncServer()
		let new = try SyncServer()
		let (model, _, _) = try await syncingMac(old, notes: ["shopping", "trip"])
		let shown = try #require(model.selection)
		await model.delete(shown)
		await model.syncNow()
		#expect(await model.turnOffSync())

		guard case let .success(.newLibrary(phrase)) = await model.prepareSync(server: new.url.absoluteString, apiKey: try apiKeyText(new)) else {
			Issue.record("the empty server did not ask for a new phrase")
			return
		}
		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(try await bodiesOn(new) == 1)
		#expect(try await bodiesOn(old) == 2)
		#expect(try await model.store?.pin() == 1)
		let (other, _) = try await mac()
		#expect(await other.joinSync(server: new.url.absoluteString, apiKey: try apiKeyText(new), phrase: entry(phrase.words)) == nil)
		await other.syncNow()
		#expect(other.notes.map(\.body) == model.notes.map(\.body))
	}

	@Test func aServerHoldingAnotherLibraryIsRefusedAndNothingChanges() async throws {
		let mine = try SyncServer()
		let theirs = try SyncServer()
		let (model, _, _) = try await syncingMac(mine, notes: ["mine"])
		let (other, _, _) = try await syncingMac(theirs, notes: ["theirs", "and more of theirs"])
		_ = other
		#expect(await model.turnOffSync())

		#expect(await model.prepareSync(server: theirs.url.absoluteString, apiKey: try apiKeyText(theirs)) == .failure(.serverHoldsAnotherLibrary))

		#expect(try await model.store?.syncSettings() == nil)
		#expect(try await bodiesOn(theirs) == 2)
	}

	@Test func changingServerWhileSyncingMovesTheLibraryAndStopsTheOldSync() async throws {
		let old = try SyncServer()
		let new = try SyncServer()
		let (model, _, _) = try await syncingMac(old, notes: ["moving"])

		guard case let .success(.newLibrary(phrase)) = await model.prepareSync(server: new.url.absoluteString, apiKey: try apiKeyText(new)) else {
			Issue.record("the empty server did not ask for a new phrase")
			return
		}
		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		model.edit(try #require(model.selection), "moved")
		await model.syncNow()

		#expect(try await model.store?.syncSettings()?.server == new.url)
		#expect(try await bodiesOn(new) == 1)
		#expect(try await bodiesOn(old) == 1)
	}

	@Test func changingToTheSameLibraryAtANewAddressReattaches() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingMac(server, notes: ["same library"])
		let before = server.url
		try server.restart()
		try #require(server.url != before)

		#expect(await model.prepareSync(server: server.url.absoluteString, apiKey: try apiKeyText(server)) == .success(.reattached))
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(try await model.store?.syncSettings()?.server == server.url)
	}
}
