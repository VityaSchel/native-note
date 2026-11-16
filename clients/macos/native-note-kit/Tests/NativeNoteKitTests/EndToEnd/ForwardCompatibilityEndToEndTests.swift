import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
private struct NewerMac {
	let connection: SyncConnection
	let cipher: NoteCipher

	init(_ server: SyncServer, joining library: AppModel) async throws {
		connection = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		cipher = NoteCipher(contentKey: try #require(try await library.store?.syncSettings()).contentKey)
	}

	func push(_ writes: [Write]) async throws -> [Status] {
		guard case let .sync(results, _, _, _) = try await connection.send(.sync(since: 0, writes: writes)) else { throw SyncError.protocolViolation }
		return results.map(\.status)
	}

	func held() async throws -> [Write] {
		var since: UInt64 = 0
		var held: [Write] = []
		while true {
			guard case let .sync(_, changes, nextSeq, more) = try await connection.send(.sync(since: since, writes: [])) else { throw SyncError.protocolViolation }
			held += changes
			guard more else { return held }
			since = nextSeq
		}
	}

	func current(_ id: UUID) async throws -> (body: String, ext: Data, v: UInt32)? {
		let blindedId = cipher.blindedId(for: id)
		guard let write = try await held().last(where: { $0.blindedId == blindedId }), case let .note(_, _, _, body, ext) = cipher.open(write) else { return nil }
		return (body, ext, write.v)
	}

	func current(withBody body: String) async throws -> (id: UUID, ext: Data)? {
		for write in try await held() {
			if case let .note(id, _, _, held, ext) = cipher.open(write), held == body { return (id, ext) }
		}
		return nil
	}
}

@MainActor @Suite(.scratch, .syncServer, .serialized, .timeLimit(.minutes(10)))
struct ForwardCompatibilityEndToEndTests {
	private let corpus = RealisticCorpus.bodies(count: 120)
	private let newerChange = "A change on the server was made by a newer version of Native Note. Update Native Note to read it."
	private let stuck = "A note can't sync: the server holds a newer version of it that this Mac could not apply."

	private func launch(in directory: URL, password: String) async throws -> AppModel {
		let model = AppModel(directory: directory, syncDelay: .seconds(3600))
		model.start()
		await model.submit(password: password)
		try #require(model.phase == .unlocked, "\(String(describing: model.failure))")
		return model
	}

	private func syncedLibrary(_ server: SyncServer, password: String) async throws -> (AppModel, URL) {
		let directory = temporaryDirectory()
		let model = try await launch(in: directory, password: password)
		try await fill(model, with: corpus)
		_ = try await setUpSync(model, server)
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle, "\(model.syncStatus.phase)")
		try #require(try await model.store?.pendingPushes().isEmpty == true)
		return (model, directory)
	}

	@Test func anExtWrittenByANewerMacSurvivesAnEditHereAConflictCopyAndARelaunch() async throws {
		let server = try SyncServer()
		let (mac, directory) = try await syncedLibrary(server, password: "this Mac")
		let newer = try await NewerMac(server, joining: mac)
		let id = UUID()
		let ext = Data("{\"pinned\":true}".utf8) + Data([0x00, 0xff])
		let written = Content.note(id: id, createdAt: 1_790_000_000_000, updatedAt: 1_790_000_000_001, body: "Written on a newer Mac", ext: ext)
		#expect(try await newer.push([newer.cipher.seal(written, v: 1)]) == [.accepted])

		await mac.syncNow()
		#expect(mac.notes.first { $0.id == id }?.body == "Written on a newer Mac")
		mac.edit(id, "Edited on this Mac")
		await mac.syncNow()

		let edited = try #require(try await newer.current(id))
		#expect((edited.body, edited.ext, edited.v) == ("Edited on this Mac", ext, 2))

		let laterExt = Data([0x02, 0x00])
		let later = Content.note(id: id, createdAt: 1_790_000_000_000, updatedAt: 1_790_000_000_002, body: "Edited again on the newer Mac", ext: laterExt)
		#expect(try await newer.push([newer.cipher.seal(later, v: 3)]) == [.accepted])
		mac.edit(id, "Typed here meanwhile")
		await mac.syncNow()

		#expect(mac.syncStatus.phase == .idle && mac.syncStatus.problems.isEmpty)
		let copy = try #require(try await newer.current(withBody: "Typed here meanwhile"))
		#expect(copy.id != id && copy.ext == ext)
		#expect(try await newer.current(id).map { ($0.body, $0.ext, $0.v) == ("Edited again on the newer Mac", laterExt, 3) } == true)

		await mac.lock()
		let relaunched = try await launch(in: directory, password: "this Mac")
		let store = try #require(relaunched.store)
		#expect(try await store.note(id: id).map { ($0.body, $0.ext, $0.dirty) == ("Edited again on the newer Mac", laterExt, false) } == true)
		#expect(try await store.note(id: copy.id).map { ($0.body, $0.ext) == ("Typed here meanwhile", ext) } == true)
		#expect(try await store.liveNotes().count == corpus.count + 2)

		relaunched.edit(id, "Edited after a relaunch")
		await relaunched.syncNow()

		#expect(try await newer.current(id).map { ($0.body, $0.ext, $0.v) == ("Edited after a relaunch", laterExt, 4) } == true)
	}

	@Test func aChangeFromANewerVersionIsSkippedAndTheNoteBehindItIsReportedAcrossARelaunch() async throws {
		let server = try SyncServer()
		let (mac, directory) = try await syncedLibrary(server, password: "this Mac")
		let newer = try await NewerMac(server, joining: mac)
		let target = try #require(mac.notes.first { !$0.body.isEmpty })
		let unseen = UUID()
		let rewritten = try sealed(newerContent(of: target.id), under: newer.cipher.blindedId(for: target.id), v: 2, contentKey: try #require(try await mac.store?.syncSettings()).contentKey)
		let added = try sealed(newerContent(of: unseen, version: 0x01, kind: 0x7f), under: newer.cipher.blindedId(for: unseen), v: 1, contentKey: try #require(try await mac.store?.syncSettings()).contentKey)
		#expect(try await newer.push([rewritten, added]) == [.accepted, .accepted])

		mac.edit(target.id, "Edited here after a newer Mac changed it")
		await mac.syncNow()

		#expect(mac.syncStatus.phase == .idle)
		#expect(mac.syncStatus.problems == [newerChange, stuck])
		#expect(mac.notes.count == corpus.count)
		#expect(!mac.notes.contains { $0.id == unseen })
		let store = try #require(mac.store)
		#expect(try await store.note(id: target.id).map { ($0.body, $0.v, $0.dirty) == ("Edited here after a newer Mac changed it", 1, true) } == true)
		#expect(try await newer.held().filter { $0.blindedId == rewritten.blindedId } == [rewritten])

		await mac.lock()
		let relaunched = try await launch(in: directory, password: "this Mac")
		await relaunched.syncNow()

		#expect(relaunched.syncStatus.phase == .idle)
		#expect(relaunched.syncStatus.problems == [stuck])
		#expect(relaunched.notes.first { $0.id == target.id }?.body == "Edited here after a newer Mac changed it")
		#expect(try await relaunched.store?.pendingPushes().map(\.id) == [target.id])
	}
}
