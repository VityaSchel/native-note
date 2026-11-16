import CryptoKit
import Foundation

extension NoteStore {
	private enum Meta: String {
		case server, apiKey, contentKey, since, pin, lastPulled, firstPushes
	}

	struct SyncAlreadySetUp: Error {}

	struct ServerAddressUnreadable: Error {}

	func syncSettings() throws -> SyncSettings? {
		guard let address = try meta(.server), let apiKey = try key(.apiKey), let contentKey = try key(.contentKey) else { return nil }
		guard let server = SyncSettings.server(from: String(decoding: address, as: UTF8.self)) else { throw ServerAddressUnreadable() }
		return SyncSettings(server: server, apiKey: apiKey, contentKey: contentKey)
	}

	func enableSync(_ settings: SyncSettings, pin: UInt32) throws {
		try connection.transaction {
			guard try key(.contentKey) == nil else { throw SyncAlreadySetUp() }
			try setMeta(.server, Data(settings.server.absoluteString.utf8))
			try settings.apiKey.withUnsafeBytes { try setMeta(.apiKey, $0) }
			try settings.contentKey.withUnsafeBytes { try setMeta(.contentKey, $0) }
			try setMeta(.since, UInt64(0).bigEndianBytes)
			try setMeta(.pin, pin.bigEndianBytes)
		}
	}

	struct SyncNotSetUp: Error {}

	struct KeptLibrary {
		let contentKey: SymmetricKey
		let pin: UInt32
		let since: UInt64
		let mark: PullMark?
	}

	func keptLibrary() throws -> KeptLibrary? {
		guard let contentKey = try key(.contentKey) else { return nil }
		return KeptLibrary(contentKey: contentKey, pin: try pin(), since: try since(), mark: try lastPulled())
	}

	func disconnectSync() throws {
		try connection.transaction {
			try deleteMeta(.server)
			try deleteMeta(.apiKey)
		}
	}

	func reattachSync(server: URL, apiKey: SymmetricKey) throws {
		try connection.transaction {
			guard try key(.contentKey) != nil else { throw SyncNotSetUp() }
			try setMeta(.server, Data(server.absoluteString.utf8))
			try apiKey.withUnsafeBytes { try setMeta(.apiKey, $0) }
		}
	}

	func moveSync(to settings: SyncSettings, pin: UInt32) throws {
		try connection.transaction {
			guard try key(.contentKey) != nil else { throw SyncNotSetUp() }
			try setMeta(.server, Data(settings.server.absoluteString.utf8))
			try settings.apiKey.withUnsafeBytes { try setMeta(.apiKey, $0) }
			try setMeta(.since, UInt64(0).bigEndianBytes)
			try setMeta(.pin, pin.bigEndianBytes)
			try deleteMeta(.lastPulled)
			try deleteMeta(.firstPushes)
			try connection.prepare("DELETE FROM note WHERE deleted = 1").step()
			try connection.prepare("UPDATE note SET v = 0, dirty = 1, pulled = 0").step()
		}
	}

	func since() throws -> UInt64 {
		try meta(.since).map { UInt64(bigEndianBytes: $0) } ?? 0
	}

	func lastPulled() throws -> PullMark? {
		guard let stored = try meta(.lastPulled), stored.count > 4 else { return nil }
		return PullMark(blindedId: Data(stored.dropLast(4)), v: UInt32(bigEndianBytes: stored.suffix(4)))
	}

	func pin() throws -> UInt32 {
		try meta(.pin).map { UInt32(bigEndianBytes: $0) } ?? 0
	}

	func setPin(_ pin: UInt32) throws {
		try setMeta(.pin, pin.bigEndianBytes)
	}

	func firstPushesAwaitingEcho() throws -> Set<UUID> {
		guard let stored = try meta(.firstPushes) else { return [] }
		let width = MemoryLayout<uuid_t>.size
		return Set(stride(from: 0, to: stored.count - stored.count % width, by: width).compactMap { UUID(bytes: Data(stored.dropFirst($0).prefix(width))) })
	}

	func awaitEchoes(ofFirstPushes ids: [UUID]) throws {
		guard !ids.isEmpty else { return }
		try connection.transaction {
			let awaited = try firstPushesAwaitingEcho().union(ids)
			try setMeta(.firstPushes, awaited.reduce(into: Data()) { $0 += $1.bytes })
		}
	}

	func commit(_ commit: Commit) throws -> Applied {
		switch commit {
		case .settleLastVersion: try settleLastVersion()
		case let .exchange(exchange): try apply(exchange)
		}
	}

	private func settleLastVersion() throws -> Applied {
		try connection.transaction {
			var applied = Applied()
			for note in try pendingPushes() where note.v == .max {
				if !note.deleted { try copy(note, into: &applied) }
				try markClean(note.id)
			}
			return applied
		}
	}

	private func apply(_ exchange: Exchange) throws -> Applied {
		try connection.transaction {
			var applied = Applied()
			for (sent, result) in zip(exchange.sent, exchange.results) {
				switch result.status {
				case .accepted:
					try acknowledge(sent, at: result.v, into: &applied)
				case .conflict:
					if let held = try note(id: sent.note.id), result.v < held.v { applied.problems.append(.serverBehind) }
				case .tooLarge:
					applied.problems.append(.tooLarge(sent.note.id))
				}
			}
			let firstPushes = try firstPushesAwaitingEcho()
			for change in exchange.changes {
				try apply(change, unacknowledged: exchange.unacknowledged, firstPushes: firstPushes, into: &applied)
			}
			if exchange.reachedHead { try deleteMeta(.firstPushes) }
			try setMeta(.since, exchange.nextSeq.bigEndianBytes)
			if let pullMark = exchange.pullMark { try setMeta(.lastPulled, pullMark.blindedId + pullMark.v.bigEndianBytes) }
			return applied
		}
	}

	private func apply(_ change: PulledChange, unacknowledged: [Data: SealedWrite], firstPushes: Set<UUID>, into applied: inout Applied) throws {
		let held = try note(id: change.content.id)
		if let held, change.v <= held.v {
			if change.v < held.v { applied.problems.append(.serverBehind) }
			return
		}
		if let ours = unacknowledged[change.writeId], ours.note.id == change.content.id, ours.write.v == change.v {
			try acknowledge(ours, at: change.v, into: &applied)
			return
		}
		let echoesADiscardedFirstPush = held == nil && change.v == 1 && firstPushes.contains(change.content.id)
		if echoesADiscardedFirstPush {
			return try deleteAfterItsFirstPush(Self.note(change, over: nil), at: change.v, into: &applied)
		}
		if let held, held.dirty, !held.deleted, held.body != change.body {
			try copy(held, into: &applied)
		}
		let pulled = Self.note(change, over: held)
		try put(pulled, pulled: true)
		applied.changed[pulled.id] = pulled
		applied.pulled.insert(pulled.id)
	}

	private func acknowledge(_ sent: SealedWrite, at v: UInt32, into applied: inout Applied) throws {
		guard var held = try note(id: sent.note.id) else {
			return try deleteAfterItsFirstPush(sent.note, at: v, into: &applied)
		}
		guard held.v < v else { return }
		held.v = v
		let unchangedSinceSealed = held.body == sent.note.body && held.updatedAt == sent.note.updatedAt && held.deleted == sent.note.deleted
		if unchangedSinceSealed { held.dirty = false }
		try put(held, pulled: false)
		applied.changed[held.id] = held
	}

	private func deleteAfterItsFirstPush(_ discarded: Note, at v: UInt32, into applied: inout Applied) throws {
		guard !discarded.deleted else { return }
		let tombstone = Note(id: discarded.id, body: "", createdAt: discarded.createdAt, updatedAt: discarded.updatedAt, deleted: true, dirty: true, v: v)
		try put(tombstone, pulled: false)
		applied.changed[tombstone.id] = tombstone
	}

	private func copy(_ note: Note, into applied: inout Applied) throws {
		let copy = note.unsyncedCopy()
		try put(copy, pulled: false)
		applied.changed[copy.id] = copy
		applied.copies[note.id] = copy.id
	}

	private func markClean(_ id: UUID) throws {
		let statement = try connection.prepare("UPDATE note SET dirty = 0 WHERE uuid = ?1")
		try statement.bind(1, id.bytes)
		try statement.step()
	}

	private static func note(_ change: PulledChange, over held: Note?) -> Note {
		switch change.content {
		case let .note(id, createdAt, updatedAt, body, ext):
			Note(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, v: change.v, ext: ext)
		case let .tombstone(id, deletedAt):
			Note(id: id, body: "", createdAt: held?.createdAt ?? deletedAt, updatedAt: deletedAt, deleted: true, v: change.v)
		}
	}

	private func metaRow(_ key: Meta) throws -> SQLiteStatement? {
		let statement = try connection.prepare("SELECT v FROM meta WHERE k = ?1")
		try statement.bind(1, key.rawValue)
		return try statement.step() ? statement : nil
	}

	private func meta(_ key: Meta) throws -> Data? {
		try metaRow(key)?.data(0)
	}

	private func key(_ key: Meta) throws -> SymmetricKey? {
		try metaRow(key)?.key(0)
	}

	private func setMeta(_ key: Meta, _ value: Data) throws {
		try value.withUnsafeBytes { try setMeta(key, $0) }
	}

	private func setMeta(_ key: Meta, _ value: UnsafeRawBufferPointer) throws {
		let statement = try connection.prepare("INSERT INTO meta (k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
		try statement.bind(1, key.rawValue)
		try statement.bind(2, value)
		try statement.step()
	}

	private func deleteMeta(_ key: Meta) throws {
		let statement = try connection.prepare("DELETE FROM meta WHERE k = ?1")
		try statement.bind(1, key.rawValue)
		try statement.step()
	}
}

nonisolated extension PulledChange {
	var body: String? {
		if case let .note(_, _, _, body, _) = content { body } else { nil }
	}
}
