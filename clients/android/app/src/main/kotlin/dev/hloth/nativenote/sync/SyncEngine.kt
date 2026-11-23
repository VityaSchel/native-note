package dev.hloth.nativenote.sync

import dev.hloth.nativenote.storage.NOTE_V_MAX
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.awaitEchoes
import dev.hloth.nativenote.storage.since
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class SyncEngine(
	private val store: NoteStore,
	settings: SyncSettings,
	transport: SyncTransport,
	private val worker: CoroutineDispatcher,
) {
	private val connection = SyncConnection(settings.apiKey, transport)
	private val cipher = NoteCipher(settings.contentKey)
	private var unacknowledged = HashMap<ByteBuffer, SealedWrite>()

	suspend fun sync(apply: suspend (Commit) -> Applied): Applied {
		val total = apply(Commit.SettleLastVersion)
		val sent = HashSet<UUID>()
		val deletedWhilePushed = HashSet<UUID>()
		val conflicts = mutableListOf<Pair<UUID, UInt>>()
		var more = true
		while (true) {
			val (since, unsent) = withContext(worker) { store.since() to store.pendingPushes().filter { it.id !in sent } }
			val (batch, tooLarge) = withContext(Dispatchers.Default) { seal(unsent, cipher) }
			sent += batch.map { it.note.id } + tooLarge
			total.problems += tooLarge.map(SyncProblem::TooLarge)
			if (batch.isEmpty() && !more) {
				total.problems += stuck(conflicts)
				return total
			}

			for (sealed in batch) unacknowledged[sealed.write.writeId.key()] = sealed
			withContext(worker) { store.awaitEchoes(batch.map { it.note }.filter { it.v == 0L }.map { it.id }) }
			val response = connection.send(Request.Sync(since, batch.map { it.write }))
			if (response !is Response.Sync || !allows(response.results, batch, response.more, response.changes, since, response.nextSeq)) {
				throw SyncError.ProtocolViolation()
			}
			if (response.nextSeq < since) {
				total.problems += SyncProblem.ServerBehind
				return total
			}
			val answered = batch.mapTo(HashSet()) { it.write.writeId.key() }
			val awaiting = unacknowledged.filterKeys { it !in answered }
			conflicts += batch.zip(response.results).filter { it.second.status == Status.Conflict }.map { it.first.note.id to it.second.v }
			val (pulled, unread) = withContext(Dispatchers.Default) { open(response.changes, cipher) }
			val pullMark = response.changes.lastOrNull()?.let { PullMark(it.blindedId, it.v) }
			val exchange = Exchange(batch, response.results, pulled, response.nextSeq, awaiting, pullMark, reachedHead = !response.more)
			val applied = apply(Commit.Apply(exchange))
			applied.problems += unread
			val resolved = pulled.mapTo(HashSet()) { it.content.id }
			unacknowledged = HashMap(awaiting.filterValues { it.note.id !in resolved })
			val tombstonesToPush = applied.changed.values.filter { it.deleted && it.dirty && deletedWhilePushed.add(it.id) }
			sent -= tombstonesToPush.map { it.id }.toSet()
			total.merge(applied)
			more = response.more
		}
	}

	private suspend fun stuck(conflicts: List<Pair<UUID, UInt>>): List<SyncProblem> {
		val stuck = mutableListOf<SyncProblem>()
		for ((id, v) in conflicts) {
			val held = withContext(worker) { store.note(id) } ?: continue
			if (held.v < v.toLong() && SyncProblem.StuckConflict(id) !in stuck) stuck += SyncProblem.StuckConflict(id)
		}
		return stuck
	}

	companion object {
		const val NOTE_MAX = 1 shl 20

		fun allows(results: List<WriteResult>, batch: List<SealedWrite>, more: Boolean, changes: List<Write>, since: ULong, nextSeq: ULong): Boolean {
			if (results.size != batch.size || (more && (changes.isEmpty() || nextSeq <= since))) return false
			return results.zip(batch).all { (result, sealed) -> result.status != Status.Accepted || result.v == sealed.write.v }
		}

		fun seal(notes: List<Note>, cipher: NoteCipher): Pair<List<SealedWrite>, List<UUID>> {
			val batch = mutableListOf<SealedWrite>()
			val tooLarge = mutableListOf<UUID>()
			var length = Request.SYNC_HEADER_LENGTH
			for (note in notes) {
				if (note.v >= NOTE_V_MAX) continue
				val content = if (note.deleted) Content.Tombstone(note.id, note.updatedAt) else Content.Note(note.id, note.createdAt, note.updatedAt, note.body, note.ext)
				val write = cipher.seal(content, (note.v + 1).toUInt())
				if (write.payload.size > NOTE_MAX) {
					tooLarge += note.id
					continue
				}
				if (length + write.encodedLength > Padding.INNER_MAX) break
				length += write.encodedLength
				batch += SealedWrite(note, write)
			}
			return batch to tooLarge
		}

		fun open(changes: List<Write>, cipher: NoteCipher): Pair<List<PulledChange>, List<SyncProblem>> {
			val pulled = mutableListOf<PulledChange>()
			val unread = mutableListOf<SyncProblem>()
			for (change in changes) {
				when (val verified = cipher.verify(change)) {
					is NoteCipher.Verified.Valid -> pulled += PulledChange(verified.content, change.v, change.writeId)
					NoteCipher.Verified.NewerVersion -> unread += SyncProblem.NewerChange
					NoteCipher.Verified.Unverifiable -> unread += SyncProblem.UnverifiableChange
				}
			}
			return pulled to unread
		}

		suspend fun holds(mark: PullMark, connection: SyncConnection, since: ULong): Boolean {
			var after = maxOf(since, 1u) - 1u
			while (true) {
				val response = connection.send(Request.Sync(after, emptyList()))
				if (response !is Response.Sync || !allows(response.results, emptyList(), response.more, response.changes, after, response.nextSeq)) {
					throw SyncError.ProtocolViolation()
				}
				if (response.changes.any { it.blindedId.contentEquals(mark.blindedId) && it.v >= mark.v }) return true
				if (!response.more) return false
				after = response.nextSeq
			}
		}
	}
}
