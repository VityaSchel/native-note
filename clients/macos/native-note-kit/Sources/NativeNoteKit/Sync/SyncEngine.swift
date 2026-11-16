import Foundation

final class SyncEngine {
	typealias Apply = (Commit) async throws -> Applied

	nonisolated static let noteMax = 1 << 20

	private let store: NoteStore
	private let connection: SyncConnection
	private let cipher: NoteCipher
	private var unacknowledged: [Data: SealedWrite] = [:]

	init(store: NoteStore, settings: SyncSettings, transport: any SyncTransport) {
		self.store = store
		connection = SyncConnection(apiKey: settings.apiKey, transport: transport)
		cipher = NoteCipher(contentKey: settings.contentKey)
	}

	func sync(apply: Apply? = nil) async throws -> Applied {
		let apply = apply ?? { [store] in try await store.commit($0) }
		var total = try await apply(.settleLastVersion)
		var sent: Set<UUID> = []
		var deletedWhilePushed: Set<UUID> = []
		var conflicts: [(id: UUID, v: UInt32)] = []
		var more = true
		while true {
			let since = try await store.since()
			let unsent = try await store.pendingPushes().filter { !sent.contains($0.id) }
			let (batch, tooLarge) = try await Self.seal(unsent, with: cipher)
			sent.formUnion(batch.map(\.note.id) + tooLarge)
			total.problems += tooLarge.map(SyncProblem.tooLarge)
			guard !batch.isEmpty || more else {
				total.problems += try await stuck(conflicts)
				return total
			}

			for sealed in batch { unacknowledged[sealed.write.writeId] = sealed }
			try await store.awaitEchoes(ofFirstPushes: batch.map(\.note).filter { $0.v == 0 }.map(\.id))
			let response = try await connection.send(.sync(since: since, writes: batch.map(\.write)))
			guard case let .sync(results, changes, nextSeq, hasMore) = response, Self.allows(results, for: batch, more: hasMore, changes: changes, since: since, nextSeq: nextSeq) else {
				throw SyncError.protocolViolation
			}
			guard nextSeq >= since else {
				total.problems.append(.serverBehind)
				return total
			}
			for sealed in batch { unacknowledged[sealed.write.writeId] = nil }
			conflicts += zip(batch, results).filter { $1.status == .conflict }.map { ($0.note.id, $1.v) }
			let (pulled, unread) = await Self.open(changes, with: cipher)
			let pullMark = changes.last.map { PullMark(blindedId: $0.blindedId, v: $0.v) }
			let exchange = Exchange(sent: batch, results: results, changes: pulled, nextSeq: nextSeq, unacknowledged: unacknowledged, pullMark: pullMark, reachedHead: !hasMore)
			var applied = try await apply(.exchange(exchange))
			applied.problems += unread
			let resolved = Set(pulled.map(\.content.id))
			unacknowledged = unacknowledged.filter { !resolved.contains($0.value.note.id) }
			let tombstonesToPush = applied.changed.values.filter { $0.deleted && $0.dirty && deletedWhilePushed.insert($0.id).inserted }
			sent.subtract(tombstonesToPush.map(\.id))
			total.merge(applied)
			more = hasMore
		}
	}

	private static func allows(
		_ results: [WriteResult],
		for batch: [SealedWrite],
		more: Bool,
		changes: [Write],
		since: UInt64,
		nextSeq: UInt64
	) -> Bool {
		guard results.count == batch.count, !more || (!changes.isEmpty && nextSeq > since) else { return false }
		return zip(results, batch).allSatisfy { result, sealed in
			result.status != .accepted || result.v == sealed.write.v
		}
	}

	@concurrent
	private nonisolated static func seal(_ notes: [Note], with cipher: NoteCipher) async throws -> (batch: [SealedWrite], tooLarge: [UUID]) {
		var batch: [SealedWrite] = []
		var tooLarge: [UUID] = []
		var length = Request.syncHeaderLength
		for note in notes where note.v < .max {
			let content: Content =
				note.deleted
				? .tombstone(id: note.id, deletedAt: note.updatedAt)
				: .note(id: note.id, createdAt: note.createdAt, updatedAt: note.updatedAt, body: note.body, ext: note.ext)
			let write = try cipher.seal(content, v: note.v + 1)
			guard write.payload.count <= noteMax else {
				tooLarge.append(note.id)
				continue
			}
			guard length + write.encodedLength <= Padding.innerMax else { break }
			length += write.encodedLength
			batch.append(SealedWrite(note: note, write: write))
		}
		return (batch, tooLarge)
	}

	@concurrent
	private nonisolated static func open(_ changes: [Write], with cipher: NoteCipher) async -> (pulled: [PulledChange], unread: [SyncProblem]) {
		var pulled: [PulledChange] = []
		var unread: [SyncProblem] = []
		for change in changes {
			switch cipher.verify(change) {
			case let .content(content): pulled.append(PulledChange(content: content, v: change.v, writeId: change.writeId))
			case .newerVersion: unread.append(.newerChange)
			case .unverifiable: unread.append(.unverifiableChange)
			}
		}
		return (pulled, unread)
	}

	private func stuck(_ conflicts: [(id: UUID, v: UInt32)]) async throws -> [SyncProblem] {
		var stuck: [SyncProblem] = []
		for conflict in conflicts {
			guard let held = try await store.note(id: conflict.id), held.v < conflict.v, !stuck.contains(.stuckConflict(conflict.id)) else { continue }
			stuck.append(.stuckConflict(conflict.id))
		}
		return stuck
	}
}

extension SyncEngine {
	static func holds(_ mark: PullMark, through connection: SyncConnection, since: UInt64) async throws -> Bool {
		var after = max(since, 1) - 1
		while true {
			guard case let .sync(results, changes, nextSeq, more) = try await connection.send(.sync(since: after, writes: [])),
				allows(results, for: [], more: more, changes: changes, since: after, nextSeq: nextSeq)
			else { throw SyncError.protocolViolation }
			if changes.contains(where: { $0.blindedId == mark.blindedId && $0.v >= mark.v }) { return true }
			guard more else { return false }
			after = nextSeq
		}
	}
}
