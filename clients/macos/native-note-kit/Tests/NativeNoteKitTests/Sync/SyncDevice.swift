import CryptoKit
import Foundation

@testable import NativeNoteKit

let sharedContentKey = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))

/// One client of a test server: its own library, engine and clock.
@MainActor
final class SyncDevice {
	let store: NoteStore
	let transport: TestTransport
	private(set) var engine: SyncEngine
	private let directory: URL
	private let settings: SyncSettings
	private let skew: Int64

	init(_ server: SyncServer, skew: Duration = .zero, contentKey: SymmetricKey = sharedContentKey) async throws {
		directory = temporaryDirectory()
		let url = AppLock.databaseFile(in: directory)
		store = try await openStore(at: url)
		transport = TestTransport(server)
		settings = SyncSettings(server: server.url, apiKey: try server.apiKey, contentKey: contentKey)
		try await store.enableSync(settings, pin: 1)
		engine = SyncEngine(store: store, settings: settings, transport: transport)
		self.skew = skew.components.seconds * 1000
	}

	deinit {
		try? FileManager.default.removeItem(at: directory)
	}

	var now: Int64 {
		Date().epochMilliseconds + skew
	}

	@discardableResult
	func write(_ body: String, to id: UUID = UUID()) async throws -> UUID {
		var note = try await store.note(id: id) ?? Note(id: id, body: "", createdAt: now, updatedAt: now)
		note.body = body
		note.updatedAt = now
		note.dirty = true
		try await store.save(note)
		return id
	}

	func delete(_ id: UUID) async throws {
		try await store.markDeleted(id: id, at: now)
	}

	@discardableResult
	func sync() async throws -> Applied {
		try await engine.sync()
	}

	/// A fresh engine, as after a relaunch, which has forgotten every unacknowledged write.
	func relaunch() {
		engine = SyncEngine(store: store, settings: settings, transport: transport)
	}

	func live() async throws -> [UUID: String] {
		Dictionary(uniqueKeysWithValues: try await store.liveNotes().map { ($0.id, $0.body) })
	}

	func note(_ id: UUID) async throws -> Note? {
		try await store.note(id: id)
	}

	var dirty: [Note] {
		get async throws { try await store.pendingPushes() }
	}
}
