package dev.hloth.nativenote.sync

import dev.hloth.nativenote.storage.Note
import java.net.URI
import java.nio.ByteBuffer
import java.util.UUID

class SyncSettings(val server: String, val apiKey: ByteArray, val contentKey: ByteArray) {
	companion object {
		fun server(address: String): String? {
			val uri = runCatching { URI(address) }.getOrNull() ?: return null
			if (uri.scheme?.lowercase() !in setOf("http", "https") || uri.host.isNullOrEmpty()) return null
			return address
		}
	}
}

class SealedWrite(val note: Note, val write: Write)

class PulledChange(val content: Content, val v: UInt, val writeId: ByteArray) {
	val body: String? get() = (content as? Content.Note)?.body
}

class PullMark(val blindedId: ByteArray, val v: UInt) {
	override fun equals(other: Any?) = other is PullMark && blindedId.contentEquals(other.blindedId) && v == other.v

	override fun hashCode() = 31 * blindedId.contentHashCode() + v.hashCode()
}

class Exchange(
	val sent: List<SealedWrite> = emptyList(),
	val results: List<WriteResult> = emptyList(),
	val changes: List<PulledChange> = emptyList(),
	val nextSeq: ULong = 0u,
	val unacknowledged: Map<ByteBuffer, SealedWrite> = emptyMap(),
	val pullMark: PullMark? = null,
	val reachedHead: Boolean = false,
)

sealed interface Commit {
	data object SettleLastVersion : Commit

	class Apply(val exchange: Exchange) : Commit
}

sealed interface SyncProblem {
	data object ServerBehind : SyncProblem

	data object UnverifiableChange : SyncProblem

	data object NewerChange : SyncProblem

	data class TooLarge(val id: UUID) : SyncProblem

	data class StuckConflict(val id: UUID) : SyncProblem
}

class Applied {
	val changed = LinkedHashMap<UUID, Note>()
	val copies = LinkedHashMap<UUID, UUID>()
	val pulled = LinkedHashSet<UUID>()
	val problems = mutableListOf<SyncProblem>()

	fun merge(other: Applied) {
		changed.putAll(other.changed)
		copies.putAll(other.copies)
		pulled.addAll(other.pulled)
		problems += other.problems
	}
}

fun ByteArray.key(): ByteBuffer = ByteBuffer.wrap(this)
