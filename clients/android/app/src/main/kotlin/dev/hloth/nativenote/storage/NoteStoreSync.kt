package dev.hloth.nativenote.storage

import dev.hloth.nativenote.sync.Applied
import dev.hloth.nativenote.sync.Commit
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.Exchange
import dev.hloth.nativenote.sync.PullMark
import dev.hloth.nativenote.sync.PulledChange
import dev.hloth.nativenote.sync.SealedWrite
import dev.hloth.nativenote.sync.Status
import dev.hloth.nativenote.sync.SyncProblem
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.bytes
import dev.hloth.nativenote.sync.key
import dev.hloth.nativenote.sync.uuidOf
import java.nio.ByteBuffer
import java.util.UUID

class SyncAlreadySetUp : Exception("sync is already set up")

class SyncNotSetUp : Exception("sync is not set up")

class ServerAddressUnreadable : Exception("the saved server address cannot be read")

class KeptLibrary(val contentKey: ByteArray, val pin: UInt, val since: ULong, val mark: PullMark?)

private enum class Meta(val key: String) {
	Server("server"),
	ApiKey("apiKey"),
	ContentKey("contentKey"),
	Since("since"),
	Pin("pin"),
	LastPulled("lastPulled"),
	FirstPushes("firstPushes"),
}

const val NOTE_V_MAX = 0xFFFF_FFFFL

fun NoteStore.syncSettings(): SyncSettings? {
	val address = meta(Meta.Server) ?: return null
	val apiKey = meta(Meta.ApiKey) ?: return null
	val contentKey = meta(Meta.ContentKey) ?: return null
	val server = SyncSettings.server(address.decodeToString()) ?: throw ServerAddressUnreadable()
	return SyncSettings(server, apiKey, contentKey)
}

fun NoteStore.enableSync(settings: SyncSettings, pin: UInt) = connection.transaction {
	if (meta(Meta.ContentKey) != null) throw SyncAlreadySetUp()
	setMeta(Meta.Server, settings.server.encodeToByteArray())
	setMeta(Meta.ApiKey, settings.apiKey)
	setMeta(Meta.ContentKey, settings.contentKey)
	setMeta(Meta.Since, ByteBuffer.allocate(8).putLong(0).array())
	setMeta(Meta.Pin, ByteBuffer.allocate(4).putInt(pin.toInt()).array())
}

fun NoteStore.keptLibrary(): KeptLibrary? {
	val contentKey = meta(Meta.ContentKey) ?: return null
	return KeptLibrary(contentKey, pin(), since(), lastPulled())
}

fun NoteStore.disconnectSync() = connection.transaction {
	deleteMeta(Meta.Server)
	deleteMeta(Meta.ApiKey)
}

fun NoteStore.reattachSync(server: String, apiKey: ByteArray) = connection.transaction {
	if (meta(Meta.ContentKey) == null) throw SyncNotSetUp()
	setMeta(Meta.Server, server.encodeToByteArray())
	setMeta(Meta.ApiKey, apiKey)
}

fun NoteStore.moveSync(settings: SyncSettings, pin: UInt) = connection.transaction {
	if (meta(Meta.ContentKey) == null) throw SyncNotSetUp()
	setMeta(Meta.Server, settings.server.encodeToByteArray())
	setMeta(Meta.ApiKey, settings.apiKey)
	setMeta(Meta.Since, ByteBuffer.allocate(8).putLong(0).array())
	setMeta(Meta.Pin, ByteBuffer.allocate(4).putInt(pin.toInt()).array())
	deleteMeta(Meta.LastPulled)
	deleteMeta(Meta.FirstPushes)
	connection.execute("DELETE FROM note WHERE deleted = 1")
	connection.execute("UPDATE note SET v = 0, dirty = 1, pulled = 0")
}

fun NoteStore.since(): ULong = meta(Meta.Since)?.let { ByteBuffer.wrap(it).long.toULong() } ?: 0u

fun NoteStore.lastPulled(): PullMark? {
	val stored = meta(Meta.LastPulled)?.takeIf { it.size > 4 } ?: return null
	return PullMark(stored.copyOf(stored.size - 4), ByteBuffer.wrap(stored, stored.size - 4, 4).int.toUInt())
}

fun NoteStore.pin(): UInt = meta(Meta.Pin)?.let { ByteBuffer.wrap(it).int.toUInt() } ?: 0u

fun NoteStore.setPin(pin: UInt) = setMeta(Meta.Pin, ByteBuffer.allocate(4).putInt(pin.toInt()).array())

fun NoteStore.firstPushesAwaitingEcho(): Set<UUID> {
	val stored = meta(Meta.FirstPushes) ?: return emptySet()
	return (0 until stored.size / 16).mapTo(HashSet()) { uuidOf(stored.copyOfRange(it * 16, it * 16 + 16)) }
}

fun NoteStore.awaitEchoes(firstPushes: List<UUID>) {
	if (firstPushes.isEmpty()) return
	connection.transaction {
		val awaited = firstPushesAwaitingEcho() + firstPushes
		setMeta(Meta.FirstPushes, awaited.fold(ByteArray(0)) { stored, id -> stored + id.bytes() })
	}
}

fun NoteStore.commit(commit: Commit): Applied = when (commit) {
	Commit.SettleLastVersion -> settleLastVersion()
	is Commit.Apply -> apply(commit.exchange)
}

private fun NoteStore.settleLastVersion(): Applied = connection.transaction {
	val applied = Applied()
	for (note in pendingPushes().filter { it.v == NOTE_V_MAX }) {
		if (!note.deleted) copy(note, applied)
		markClean(note.id)
	}
	applied
}

private fun NoteStore.apply(exchange: Exchange): Applied = connection.transaction {
	val applied = Applied()
	for ((sent, result) in exchange.sent.zip(exchange.results)) {
		when (result.status) {
			Status.Accepted -> acknowledge(sent, result.v.toLong(), applied)
			Status.Conflict -> note(sent.note.id)?.let { if (result.v.toLong() < it.v) applied.problems += SyncProblem.ServerBehind }
			Status.TooLarge -> applied.problems += SyncProblem.TooLarge(sent.note.id)
		}
	}
	val firstPushes = firstPushesAwaitingEcho()
	for (change in exchange.changes) apply(change, exchange.unacknowledged, firstPushes, applied)
	if (exchange.reachedHead) deleteMeta(Meta.FirstPushes)
	setMeta(Meta.Since, ByteBuffer.allocate(8).putLong(exchange.nextSeq.toLong()).array())
	exchange.pullMark?.let { setMeta(Meta.LastPulled, it.blindedId + ByteBuffer.allocate(4).putInt(it.v.toInt()).array()) }
	applied
}

private fun NoteStore.apply(change: PulledChange, unacknowledged: Map<ByteBuffer, SealedWrite>, firstPushes: Set<UUID>, applied: Applied) {
	val v = change.v.toLong()
	val held = note(change.content.id)
	if (held != null && v <= held.v) {
		if (v < held.v) applied.problems += SyncProblem.ServerBehind
		return
	}
	val ours = unacknowledged[change.writeId.key()]
	if (ours != null && ours.note.id == change.content.id && ours.write.v == change.v) return acknowledge(ours, v, applied)
	if (held == null && v == 1L && change.content.id in firstPushes) return deleteAfterItsFirstPush(pulledNote(change, null), v, applied)
	if (held != null && held.dirty && !held.deleted && held.body != change.body) copy(held, applied)
	val pulled = pulledNote(change, held)
	put(pulled, pulled = true)
	applied.changed[pulled.id] = pulled
	applied.pulled += pulled.id
}

private fun NoteStore.acknowledge(sent: SealedWrite, v: Long, applied: Applied) {
	val held = note(sent.note.id) ?: return deleteAfterItsFirstPush(sent.note, v, applied)
	if (held.v >= v) return
	val unchangedSinceSealed = held.body == sent.note.body && held.updatedAt == sent.note.updatedAt && held.deleted == sent.note.deleted
	val acknowledged = Note(held.id, held.body, held.createdAt, held.updatedAt, held.deleted, held.dirty && !unchangedSinceSealed, v, held.ext)
	put(acknowledged, pulled = false)
	applied.changed[acknowledged.id] = acknowledged
}

private fun NoteStore.deleteAfterItsFirstPush(discarded: Note, v: Long, applied: Applied) {
	if (discarded.deleted) return
	val tombstone = Note(discarded.id, "", discarded.createdAt, discarded.updatedAt, deleted = true, dirty = true, v = v)
	put(tombstone, pulled = false)
	applied.changed[tombstone.id] = tombstone
}

private fun NoteStore.copy(note: Note, applied: Applied) {
	val copy = note.unsyncedCopy()
	put(copy, pulled = false)
	applied.changed[copy.id] = copy
	applied.copies[note.id] = copy.id
}

private fun NoteStore.markClean(id: UUID) = connection.prepare("UPDATE note SET dirty = 0 WHERE uuid = ?1").use {
	it.bind(1, id.bytes())
	it.step()
}

private fun pulledNote(change: PulledChange, held: Note?): Note = when (val content = change.content) {
	is Content.Note -> Note(content.id, content.body, content.createdAt, content.updatedAt, v = change.v.toLong(), ext = content.ext)
	is Content.Tombstone -> Note(content.id, "", held?.createdAt ?: content.deletedAt, content.deletedAt, deleted = true, v = change.v.toLong())
}

private fun NoteStore.meta(key: Meta): ByteArray? = connection.prepare("SELECT v FROM meta WHERE k = ?1").use {
	it.bind(1, key.key)
	if (it.step()) it.bytes(0) else null
}

private fun NoteStore.setMeta(key: Meta, value: ByteArray) =
	connection.prepare("INSERT INTO meta (k, v) VALUES (?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v").use {
		it.bind(1, key.key)
		it.bind(2, value)
		it.step()
	}

private fun NoteStore.deleteMeta(key: Meta) = connection.prepare("DELETE FROM meta WHERE k = ?1").use {
	it.bind(1, key.key)
	it.step()
}
