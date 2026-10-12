import CryptoKit
import Foundation

/// Sync state in `meta` and the transaction that applies a response, per clients/DESIGN.md § Conflicts.
extension NoteStore {
	private enum Meta: String {
		case server, apiKey, contentKey, since, pin
	}

	func syncSettings() throws -> SyncSettings? {
		guard let server = try meta(.server).flatMap({ URL(string: String(decoding: $0, as: UTF8.self)) }),
			let apiKey = try key(.apiKey),
			let contentKey = try key(.contentKey)
		else { return nil }
		return SyncSettings(server: server, apiKey: apiKey, contentKey: contentKey)
	}

	func enableSync(_ settings: SyncSettings, pin: UInt32) throws {
		try connection.transaction {
			try setMeta(.server, Data(settings.server.absoluteString.utf8))
			try settings.apiKey.withUnsafeBytes { try setMeta(.apiKey, $0) }
			try settings.contentKey.withUnsafeBytes { try setMeta(.contentKey, $0) }
			try setMeta(.since, Self.bigEndian(UInt64(0)))
			try setMeta(.pin, Self.bigEndian(pin))
		}
	}

	func since() throws -> UInt64 {
		try meta(.since).map { Self.integer($0) } ?? 0
	}

	func pin() throws -> UInt32 {
		try meta(.pin).map { UInt32(truncatingIfNeeded: Self.integer($0)) } ?? 0
	}

	func setPin(_ pin: UInt32) throws {
		try setMeta(.pin, Self.bigEndian(pin))
	}

	func commit(_ commit: Commit) throws -> Applied {
		switch commit {
		case .settleLastVersion: try settleLastVersion()
		case let .exchange(exchange): try apply(exchange)
		}
	}

	/// A dirty note at the last version takes no write: its text moves to a copy, and the original stays as it is, clean.
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
			for change in exchange.changes {
				try apply(change, unacknowledged: exchange.unacknowledged, into: &applied)
			}
			try setMeta(.since, Self.bigEndian(exchange.nextSeq))
			return applied
		}
	}

	private func apply(_ change: PulledChange, unacknowledged: [Data: SealedWrite], into applied: inout Applied) throws {
		let held = try note(id: change.content.id)
		if let held, change.v <= held.v {
			if change.v < held.v { applied.problems.append(.serverBehind) }
			return
		}
		if let ours = unacknowledged[change.writeId], ours.note.id == change.content.id, ours.write.v == change.v {
			try acknowledge(ours, at: change.v, into: &applied)
			return
		}
		if let held, held.dirty, !held.deleted, held.body != change.body {
			try copy(held, into: &applied)
		}
		let pulled = Self.note(change, over: held)
		try put(pulled, pulled: true)
		applied.changed[pulled.id] = pulled
		applied.pulled.insert(pulled.id)
	}

	/// Sets the stored `v`, and clears `dirty` only if the note was not saved after the write was sealed.
	private func acknowledge(_ sent: SealedWrite, at v: UInt32, into applied: inout Applied) throws {
		guard var held = try note(id: sent.note.id), held.v < v else { return }
		held.v = v
		if held.body == sent.note.body, held.updatedAt == sent.note.updatedAt, held.deleted == sent.note.deleted {
			held.dirty = false
		}
		try put(held, pulled: false)
		applied.changed[held.id] = held
	}

	private func copy(_ note: Note, into applied: inout Applied) throws {
		let copy = Note(id: UUID(), body: note.body, createdAt: note.createdAt, updatedAt: note.updatedAt, dirty: true)
		try put(copy, pulled: false)
		applied.changed[copy.id] = copy
		applied.copies[note.id] = copy.id
	}

	private func markClean(_ id: UUID) throws {
		let statement = try connection.prepare("UPDATE note SET dirty = 0 WHERE uuid = ?1")
		statement.bind(1, id.bytes)
		try statement.step()
	}


	private static func note(_ change: PulledChange, over held: Note?) -> Note {
		switch change.content {
		case let .note(id, createdAt, updatedAt, body):
			Note(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, v: change.v)
		case let .tombstone(id, deletedAt):
			Note(id: id, body: "", createdAt: held?.createdAt ?? deletedAt, updatedAt: deletedAt, deleted: true, v: change.v)
		}
	}

	private func meta(_ key: Meta) throws -> Data? {
		let statement = try connection.prepare("SELECT v FROM meta WHERE k = ?1")
		statement.bind(1, key.rawValue)
		return try statement.step() ? statement.data(0) : nil
	}

	private func key(_ key: Meta) throws -> SymmetricKey? {
		let statement = try connection.prepare("SELECT v FROM meta WHERE k = ?1")
		statement.bind(1, key.rawValue)
		return try statement.step() ? statement.key(0) : nil
	}

	private func setMeta(_ key: Meta, _ value: Data) throws {
		try value.withUnsafeBytes { try setMeta(key, $0) }
	}

	private func setMeta(_ key: Meta, _ value: UnsafeRawBufferPointer) throws {
		let statement = try connection.prepare("INSERT INTO meta (k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v")
		statement.bind(1, key.rawValue)
		statement.bind(2, value)
		try statement.step()
	}

	private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
		withUnsafeBytes(of: value.bigEndian) { Data($0) }
	}

	private static func integer(_ bytes: Data) -> UInt64 {
		bytes.reduce(0) { $0 << 8 | UInt64($1) }
	}
}

nonisolated extension PulledChange {
	var body: String? {
		if case let .note(_, _, _, body) = content { body } else { nil }
	}
}
