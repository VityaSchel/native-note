import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct SyncOffAndMoveTests {
	private final class HeldRequest: @unchecked Sendable {
		private let lock = NSLock()
		private var armed = false
		private var sent = false
		private var waiting: CheckedContinuation<Void, Never>?

		func holdNext() {
			lock.withLock {
				armed = true
				sent = false
			}
		}

		func held() async {
			await withCheckedContinuation { continuation in
				lock.withLock { sent ? continuation.resume() : (waiting = continuation) }
			}
		}

		func transport(to url: URL) -> any SyncTransport {
			Gate(url: url, held: self)
		}

		fileprivate func takes() -> Bool {
			lock.withLock {
				guard armed else { return false }
				armed = false
				sent = true
				waiting?.resume()
				waiting = nil
				return true
			}
		}

		private struct Gate: SyncTransport {
			let url: URL
			let held: HeldRequest

			func post(_ body: Data) async throws -> Data {
				guard held.takes() else { return try await HTTPTransport(url: url).post(body) }
				do {
					try await Task.sleep(for: .seconds(600))
				} catch {
					throw URLError(.cancelled)
				}
				return Data()
			}
		}
	}

	@MainActor private final class PhaseLog {
		var phases: [AppModel.SyncStatus.Phase] = []
		var watching = true

		var sawAFailure: Bool {
			phases.contains { if case .failed = $0 { true } else { false } }
		}
	}

	private func mac(holding held: HeldRequest? = nil) async throws -> (AppModel, URL) {
		guard let held else { return try await unlockedModel { AppModel.testing(in: $0) } }
		return try await unlockedModel { directory in AppModel.testing(in: directory, makeTransport: { held.transport(to: $0) }) }
	}

	private func syncingMac(_ server: SyncServer, notes: [String], holding held: HeldRequest? = nil) async throws -> (AppModel, URL, AppModel.RecoveryPhrase) {
		let (model, directory) = try await mac(holding: held)
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

		#expect(await model.turnOffSync() == nil)

		#expect(model.syncStatus.server == nil && model.syncStatus.phase == .off)
		#expect(Set(model.notes.map(\.body)) == ["kept", "also kept"])
		model.edit(try #require(model.selection), "edited while off")
		await model.syncNow()
		#expect(try await bodiesOn(server) == 2)
		#expect(try await model.store?.syncSettings() == nil)
		#expect(try await model.store?.keptLibrary() != nil)
	}

	@Test func aTurnOffThatCannotWriteKeepsSyncAndHandsItsFailureBackWithoutAnAlert() async throws {
		let server = try SyncServer()
		let (model, directory, _) = try await syncingMac(server, notes: ["kept syncing"])
		try await model.store?.failAtOnceWhenLocked()
		let blocker = try await connection(to: directory)
		try blocker.execute("BEGIN IMMEDIATE")

		let failure = await model.turnOffSync()
		try blocker.execute("ROLLBACK")

		#expect(failure == .failed("database is locked", title: "Sync could not be turned off."))
		#expect(model.failure == nil)
		#expect(model.syncStatus.server == server.url.absoluteString)
		#expect(try await model.store?.syncSettings()?.server == server.url)
	}

	@Test func turningSyncOffWhileASyncIsInFlightLeavesNoFailureBehind() async throws {
		let server = try SyncServer()
		let held = HeldRequest()
		let (model, _, _) = try await syncingMac(server, notes: ["kept"], holding: held)
		held.holdNext()
		let syncing = Task { await model.syncNow() }
		await held.held()

		#expect(await model.turnOffSync() == nil)
		await syncing.value

		#expect(model.syncStatus == AppModel.SyncStatus())
	}

	@Test func turningSyncOffNeedsAnUnlockedLibraryAndLeavesSyncAsItWas() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingMac(server, notes: ["still syncing"])
		await model.lock()

		#expect(await model.turnOffSync() == .unexpected("Unlock Native Note to turn off sync."))
		#expect(model.failure == nil)

		await model.unlock(password: workspacePassword)
		#expect(try await model.store?.syncSettings()?.server == server.url)
	}

	@Test func settingUpAgainOnTheSameServerReattachesWithoutWordsAndSendsWhatChanged() async throws {
		let server = try SyncServer()
		let (model, _, _) = try await syncingMac(server, notes: ["first"])
		let pin = try await model.store?.pin()
		#expect(await model.turnOffSync() == nil)
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
		#expect(await model.turnOffSync() == nil)

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
		#expect(await model.turnOffSync() == nil)

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

	@Test func movingToAnEmptyServerWhileASyncIsInFlightNeverShowsTheStoppedSyncAsFailed() async throws {
		let old = try SyncServer()
		let new = try SyncServer()
		let held = HeldRequest()
		let (model, _, _) = try await syncingMac(old, notes: ["moving"], holding: held)
		guard case let .success(.newLibrary(phrase)) = await model.prepareSync(server: new.url.absoluteString, apiKey: try apiKeyText(new)) else {
			Issue.record("the empty server did not ask for a new phrase")
			return
		}
		held.holdNext()
		let syncing = Task { await model.syncNow() }
		await held.held()
		let log = PhaseLog()
		let watcher = Task {
			while log.watching {
				log.phases.append(model.syncStatus.phase)
				await Task.yield()
			}
		}

		#expect(await model.finishSync(answers: answers(phrase)) == nil)
		log.watching = false
		await watcher.value
		await syncing.value

		#expect(!log.sawAFailure, "\(log.phases)")
		#expect(model.syncStatus.server == new.url.absoluteString)
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
