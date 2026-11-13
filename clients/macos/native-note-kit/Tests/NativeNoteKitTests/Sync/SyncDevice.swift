import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

let sharedContentKey = SymmetricKey(data: Data((0 ..< 32).map { UInt8($0) }))

@MainActor
final class SyncDevice {
	let store: NoteStore
	let transport: TestTransport
	private(set) var engine: SyncEngine
	private let settings: SyncSettings
	private let skew: Int64

	init(_ server: SyncServer, skew: Duration = .zero, contentKey: SymmetricKey = sharedContentKey) async throws {
		store = try await openStore(at: temporaryDatabase())
		transport = TestTransport(server)
		settings = SyncSettings(server: server.url, apiKey: try server.apiKey, contentKey: contentKey)
		try await store.enableSync(settings, pin: 1)
		engine = SyncEngine(store: store, settings: settings, transport: transport)
		self.skew = skew.components.seconds * 1000
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
