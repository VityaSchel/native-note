import Foundation

/// Pushes dirty notes and pulls by `seq` until caught up, per clients/DESIGN.md § Pull verification and § Conflicts.
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

	/// Each response goes through `apply`, which commits it; a caller with unsaved edits wraps the commit.
	func sync(apply: Apply? = nil) async throws -> Applied {
		let apply = apply ?? { [store] in try await store.commit($0) }
		var total = try await apply(.settleLastVersion)
		var sent: Set<UUID> = []
		var more = true
		while true {
			let since = try await store.since()
			let unsent = try await store.pendingPushes().filter { !sent.contains($0.id) }
			let (batch, tooLarge) = try await Self.seal(unsent, with: cipher)
			sent.formUnion(batch.map(\.note.id) + tooLarge)
			total.problems += tooLarge.map(SyncProblem.tooLarge)
			guard !batch.isEmpty || more else { return total }

			for sealed in batch { unacknowledged[sealed.write.writeId] = sealed }
			let response = try await connection.send(.sync(since: since, writes: batch.map(\.write)))
			guard case let .sync(results, changes, nextSeq, hasMore) = response, Self.allows(results, for: batch, more: hasMore, changes: changes, since: since, nextSeq: nextSeq) else {
				throw SyncError.protocolViolation
			}
			guard nextSeq >= since else {
				total.problems.append(.serverBehind)
				return total
			}
			for sealed in batch { unacknowledged[sealed.write.writeId] = nil }
			let (pulled, unverifiable) = await Self.open(changes, with: cipher)
			let exchange = Exchange(sent: batch, results: results, changes: pulled, nextSeq: nextSeq, unacknowledged: unacknowledged)
			var applied = try await apply(.exchange(exchange))
			applied.problems += Array(repeating: .unverifiableChange, count: unverifiable)
			let resolved = Set(pulled.map(\.content.id))
			unacknowledged = unacknowledged.filter { !resolved.contains($0.value.note.id) }
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
			result.status != .accepted || (result.v == sealed.write.v && result.seq != 0)
		}
	}

	/// Seals every dirty note that fits the note limit, as many as fit one request.
	@concurrent
	private nonisolated static func seal(_ notes: [Note], with cipher: NoteCipher) async throws -> (batch: [SealedWrite], tooLarge: [UUID]) {
		var batch: [SealedWrite] = []
		var tooLarge: [UUID] = []
		var length = Request.syncHeaderLength
		for note in notes where note.v < .max {
			let content: Content =
				note.deleted
				? .tombstone(id: note.id, deletedAt: note.updatedAt)
				: .note(id: note.id, createdAt: note.createdAt, updatedAt: note.updatedAt, body: note.body)
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
	private nonisolated static func open(_ changes: [Write], with cipher: NoteCipher) async -> (pulled: [PulledChange], unverifiable: Int) {
		var pulled: [PulledChange] = []
		for change in changes {
			guard let content = cipher.open(change), cipher.blindedId(for: content.id) == change.blindedId else { continue }
			pulled.append(PulledChange(content: content, v: change.v, writeId: change.writeId))
		}
		return (pulled, changes.count - pulled.count)
	}
}
