import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import NativeNoteKit

@MainActor
private final class Tally {
	private(set) var count = 0

	func add() {
		count += 1
	}
}

private final class HeldTransport: SyncTransport, Sendable {
	let server = ScriptedServer()
	let gate = Alarm()

	func post(_ body: Data) async throws -> Data {
		try await gate.sleep(for: .zero)
		return try await server.post(body)
	}
}

private final class TimedTransport: SyncTransport, Sendable {
	let server = ScriptedServer()
	private let arrivals = Mutex<[ContinuousClock.Instant]>([])

	var posted: [ContinuousClock.Instant] { arrivals.withLock { $0 } }

	func post(_ body: Data) async throws -> Data {
		arrivals.withLock { $0.append(.now) }
		return try await server.post(body)
	}
}

private struct GarbledReplies: SyncTransport {
	let reply: Data

	func post(_ body: Data) async throws -> Data {
		reply
	}
}

private func acceptingEveryWrite(_ request: Request) -> Response {
	guard case let .sync(since, writes) = request else { return .error }
	let results = writes.enumerated().map { WriteResult(status: .accepted, v: $1.v, seq: since + UInt64($0) + 1) }
	return .sync(results: results, changes: [], nextSeq: since + UInt64(writes.count), more: false)
}

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct SyncLoopTests {
	private let alarm = Alarm()
	private let address = "http://notes.example/"

	private func library(through transport: any SyncTransport, idle: Duration = .seconds(3600), holding bodies: [String] = []) async throws -> AppModel {
		try await Workspace(holding: bodies) { [alarm] directory, keys in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys, makeTransport: { _ in transport }, syncDelay: idle)
		}.unlocked(FakeKeyStore()).0
	}

	private func startSync(of model: AppModel, apiKey: SymmetricKey) async throws {
		let store = try #require(model.store)
		try await store.enableSync(SyncSettings(server: try #require(URL(string: address)), apiKey: apiKey, contentKey: sharedContentKey), pin: 1)
		await model.sync.start(store)
	}

	private func text(_ key: SymmetricKey) -> String {
		NativeNoteKit.Hex.string(key.withUnsafeBytes { Array($0) })
	}

	@Test func syncNowCallsMadeDuringASyncAreAllAnsweredByOneMoreSync() async throws {
		let transport = HeldTransport()
		transport.server.answer(acceptingEveryWrite)
		transport.server.answer(acceptingEveryWrite)
		let model = try await library(through: transport)
		try await startSync(of: model, apiKey: transport.server.apiKey)
		try await settle { await transport.gate.sleeping == 1 }
		let asked = Tally()
		let answered = Tally()
		let callers = (0 ..< 3).map { _ in
			Task {
				asked.add()
				await model.syncNow()
				answered.add()
			}
		}
		try await settle { asked.count == 3 }

		await transport.gate.ring()
		try await settle { await transport.gate.sleeping == 1 }
		#expect(answered.count == 0)
		#expect(transport.server.requests.count == 1)
		await transport.gate.ring()
		for caller in callers { await caller.value }

		#expect(answered.count == 3)
		#expect(transport.server.requests.count == 2)
		#expect(await transport.gate.started == 2)
		#expect(model.syncStatus.phase == .idle)
		#expect(model.sync.syncLoop == nil)
	}

	@Test func aSyncNowCallAfterTheLoopEndedRunsItsOwnSync() async throws {
		let transport = HeldTransport()
		transport.server.answerEvery(acceptingEveryWrite)
		let model = try await library(through: transport)
		try await startSync(of: model, apiKey: transport.server.apiKey)
		try await ring(transport.gate)
		try await settle { model.sync.syncLoop == nil }
		let served = transport.server.requests.count

		let asking = Task { await model.syncNow() }
		try await ring(transport.gate)
		await asking.value

		#expect(transport.server.requests.count == served + 1)
		#expect(model.syncStatus.phase == .idle)
	}

	@Test func anEditDuringTheIdleWaitStartsTheWaitAgain() async throws {
		let idle = Duration.milliseconds(400)
		let transport = TimedTransport()
		transport.server.answerEvery(acceptingEveryWrite)
		let model = try await library(through: transport, idle: idle, holding: ["typed"])
		try await startSync(of: model, apiKey: transport.server.apiKey)
		await model.syncNow()
		let id = try #require(model.selection)
		let before = transport.posted.count

		let first = ContinuousClock.now
		model.edit(id, "typed, then more")
		try await settle { ContinuousClock.now - first >= idle / 2 }
		let last = ContinuousClock.now
		model.edit(id, "typed, then more, then the rest")
		try await settle { transport.posted.count > before }

		let pushed = try #require(transport.posted.dropFirst(before).first)
		#expect(pushed - last >= idle, "the sync came \(pushed - last) after the last edit")
		await model.syncNow()
		#expect(try await model.store?.pendingPushes().isEmpty == true)
		#expect(model.syncStatus.phase == .idle)
	}

	@Test func anEditWithSyncOffSchedulesNoSync() async throws {
		let transport = TimedTransport()
		let model = try await library(through: transport, idle: .zero, holding: ["typed"])

		model.edit(try #require(model.selection), "typed with sync off")
		await model.syncNow()
		await model.flushPendingSaves()

		#expect(transport.posted.isEmpty)
		#expect(model.syncStatus.phase == .off)
	}

	@Test func aServerThatCannotStoreSaysSoWhenSyncingAndWhenSettingUp() async throws {
		let server = ScriptedServer()
		server.answerEvery { _ in .error }
		let reason = "The server could not store the changes. Its disk may be full."
		let syncing = try await library(through: server)
		try await startSync(of: syncing, apiKey: server.apiKey)

		await syncing.syncNow()

		#expect(syncing.syncStatus.phase == .failed(reason))
		#expect(syncing.syncStatus.lastSynced == nil)
		let settingUp = try await library(through: server)
		#expect(await settingUp.prepareSync(server: address, apiKey: text(server.apiKey)) == .failure(.failed(reason)))
		#expect(try await settingUp.store?.syncSettings() == nil)
	}

	@Test(arguments: [Data(), Data(repeating: 0x5a, count: 28), Data(repeating: 0x5a, count: 4096)])
	func aReplyThatDoesNotOpenReadsAsARefusedKeyWhenSyncingAndWhenSettingUp(reply: Data) async throws {
		let transport = GarbledReplies(reply: reply)
		let apiKey = SymmetricKey(size: .bits256)
		let syncing = try await library(through: transport)
		try await startSync(of: syncing, apiKey: apiKey)

		await syncing.syncNow()

		#expect(syncing.syncStatus.phase == .failed("The server did not accept this Mac's API key, or a proxy in front of it changed the request."))
		let settingUp = try await library(through: transport)
		#expect(await settingUp.prepareSync(server: address, apiKey: text(apiKey)) == .failure(.refused))
		#expect(try await settingUp.store?.syncSettings() == nil)
	}

	@Test func aNoteTheServerAnswersTooLargeIsNamedInTheStatusAndStaysToBePushed() async throws {
		let server = ScriptedServer()
		server.answerEvery { request in
			guard case let .sync(since, writes) = request else { return .error }
			return .sync(results: writes.map { _ in WriteResult(status: .tooLarge, v: 0, seq: 0) }, changes: [], nextSeq: since, more: false)
		}
		let model = try await library(through: server, holding: ["kept on this Mac"])
		try await startSync(of: model, apiKey: server.apiKey)

		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(model.syncStatus.problems == ["A note is larger than 1 MB, so it stays on this Mac until it is shorter."])
		#expect(try await model.store?.pendingPushes().map(\.body) == ["kept on this Mac"])
		#expect(model.notes.map(\.body) == ["kept on this Mac"])
	}
}
