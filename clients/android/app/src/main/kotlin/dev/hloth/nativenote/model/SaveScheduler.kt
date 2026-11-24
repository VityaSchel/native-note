package dev.hloth.nativenote.model

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class SaveScheduler(
	private val scope: CoroutineScope,
	private val delayMillis: Long = 300,
	private val sleep: suspend (Long) -> Unit = { delay(it) },
) {
	private class Pending(var save: suspend () -> Boolean, val deadline: Job)

	private val pending = HashMap<UUID, Pending>()
	private val writing = HashMap<UUID, Deferred<Boolean>>()
	private var discarding = false
	private var holds = 0

	fun schedule(id: UUID, save: suspend () -> Boolean) {
		if (discarding) return
		pending[id]?.let {
			it.save = save
			return
		}
		val deadline = scope.launch {
			sleep(delayMillis)
			if (holds == 0) flush(id)
		}
		pending[id] = Pending(save, deadline)
	}

	suspend fun flush(id: UUID): Boolean {
		pending.remove(id)?.let { due ->
			if (due.deadline !== currentCoroutineContext()[Job]) due.deadline.cancel()
			val previous = writing[id]
			writing[id] = scope.async {
				previous?.await()
				due.save()
			}
		}
		val latest = writing[id] ?: return true
		val landed = latest.await()
		if (writing[id] === latest) writing.remove(id)
		return landed
	}

	suspend fun flushAll(): Boolean {
		var landed = true
		for (id in pending.keys + writing.keys) {
			var saved = flush(id)
			if (!saved && id in pending) saved = flush(id)
			landed = saved && landed
		}
		return landed
	}

	fun isPending(id: UUID) = id in pending

	val isHeld get() = holds > 0

	fun hold() {
		holds++
	}

	fun release() {
		holds--
		if (holds == 0) scope.launch { flushAll() }
	}

	fun cancel(id: UUID) {
		pending.remove(id)?.deadline?.cancel()
	}

	suspend fun discard(id: UUID) {
		cancel(id)
		flush(id)
	}

	suspend fun discardAll() {
		discarding = true
		try {
			pending.values.forEach { it.deadline.cancel() }
			pending.clear()
			writing.values.toList().forEach { it.await() }
			writing.clear()
		} finally {
			discarding = false
		}
	}
}
