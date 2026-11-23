package dev.hloth.nativenote.model

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SaveSchedulerTest {
	private class Alarm {
		private val waiting = mutableListOf<CompletableDeferred<Unit>>()
		val delays = mutableListOf<Long>()
		val started get() = delays.size
		val sleeping get() = waiting.count { !it.isCompleted }

		suspend fun sleep(millis: Long) {
			delays += millis
			val gate = CompletableDeferred<Unit>()
			waiting += gate
			gate.await()
		}

		fun ring() = waiting.forEach { it.complete(Unit) }
	}

	private val alarm = Alarm()
	private val saves = mutableListOf<Int>()

	private fun test(body: suspend CoroutineScope.(SaveScheduler) -> Unit) = runBlocking {
		val scope = CoroutineScope(coroutineContext + SupervisorJob())
		try {
			withTimeout(10_000) { body(SaveScheduler(scope, sleep = alarm::sleep)) }
		} finally {
			scope.coroutineContext[Job]!!.cancel()
		}
	}

	private suspend fun settle(condition: () -> Boolean) {
		repeat(1_000) {
			if (condition()) return
			yield()
		}
		check(condition()) { "the condition never held" }
	}

	private suspend fun ring(sleepers: Int = 1) {
		settle { alarm.sleeping >= sleepers }
		alarm.ring()
	}

	private fun save(value: Int): suspend () -> Boolean = {
		saves += value
		true
	}

	@Test
	fun coalescesABurstIntoOneSaveOfTheLatestEdit() = test { scheduler ->
		val id = UUID.randomUUID()
		for (value in 0 until 5) scheduler.schedule(id, save(value))
		ring()
		settle { saves.isNotEmpty() }

		assertEquals(listOf(4), saves)
		assertEquals(listOf(300L), alarm.delays)
	}

	@Test
	fun keepsTheFirstDeadlineWhileEditsContinue() = test { scheduler ->
		val id = UUID.randomUUID()
		scheduler.schedule(id, save(1))
		scheduler.schedule(id, save(2))
		ring()
		settle { saves == listOf(2) }
		scheduler.schedule(id, save(3))
		ring()
		settle { saves == listOf(2, 3) }

		assertEquals(2, alarm.started)
	}

	@Test
	fun savesForDifferentNotesDoNotCancelEachOther() = test { scheduler ->
		scheduler.schedule(UUID.randomUUID(), save(1))
		scheduler.schedule(UUID.randomUUID(), save(2))
		ring(sleepers = 2)
		settle { saves.size == 2 }

		assertEquals(listOf(1, 2), saves.sorted())
	}

	@Test
	fun flushWritesImmediatelyAndCancelsThePendingWrite() = test { scheduler ->
		val id = UUID.randomUUID()
		scheduler.schedule(id, save(1))
		assertTrue(scheduler.flush(id))
		assertEquals(listOf(1), saves)

		assertTrue(scheduler.flushAll())
		settle { alarm.sleeping == 0 }
		assertEquals(listOf(1), saves)
		assertFalse(scheduler.isPending(id))
	}

	@Test
	fun writesForOneNoteLandInOrder() = test { scheduler ->
		val id = UUID.randomUUID()
		val slowWrite = CompletableDeferred<Unit>()
		scheduler.schedule(id) {
			saves += 0
			slowWrite.await()
			saves += 1
			true
		}
		val first = async { scheduler.flush(id) }
		settle { saves == listOf(0) }
		scheduler.schedule(id, save(2))
		val second = async { scheduler.flush(id) }
		yield()
		slowWrite.complete(Unit)
		first.await()
		second.await()

		assertEquals(listOf(0, 1, 2), saves)
	}

	@Test
	fun reportsAWriteThatFailed() = test { scheduler ->
		val failing = UUID.randomUUID()
		scheduler.schedule(failing) { false }
		scheduler.schedule(UUID.randomUUID()) { true }

		assertFalse(scheduler.flushAll())
		assertTrue(scheduler.flush(failing))
	}

	@Test
	fun flushAllGivesARequeuedWriteOneMoreTry() = test { scheduler ->
		val id = UUID.randomUUID()
		scheduler.schedule(id) {
			scheduler.schedule(id, save(2))
			false
		}

		assertTrue(scheduler.flushAll())
		assertEquals(listOf(2), saves)
	}

	@Test
	fun discardDropsThePendingWrite() = test { scheduler ->
		val id = UUID.randomUUID()
		scheduler.schedule(id, save(1))
		scheduler.discard(id)
		scheduler.flushAll()

		assertEquals(emptyList<Int>(), saves)
	}

	@Test
	fun discardingAllDropsASaveScheduledWhileItWaits() = test { scheduler ->
		val id = UUID.randomUUID()
		val held = CompletableDeferred<Unit>()
		var waiting = false
		scheduler.schedule(id) {
			waiting = true
			held.await()
			scheduler.schedule(id, save(2))
			false
		}
		val flushing = async { scheduler.flush(id) }
		settle { waiting }

		val discarding = async { scheduler.discardAll() }
		yield()
		held.complete(Unit)
		flushing.await()
		discarding.await()

		assertTrue(scheduler.flushAll())
		assertEquals(emptyList<Int>(), saves)

		scheduler.schedule(id, save(3))
		assertTrue(scheduler.flushAll())
		assertEquals(listOf(3), saves)
	}

	@Test
	fun aHoldDefersTheDeadlineUntilReleased() = test { scheduler ->
		val id = UUID.randomUUID()
		scheduler.hold()
		scheduler.schedule(id, save(1))
		ring()
		repeat(20) { yield() }
		assertEquals(emptyList<Int>(), saves)
		assertTrue(scheduler.isPending(id))

		scheduler.release()
		settle { saves == listOf(1) }
	}

	@Test
	fun theDefaultSleepFiresTheSave() = runBlocking {
		val scope = CoroutineScope(coroutineContext + SupervisorJob())
		val scheduler = SaveScheduler(scope, delayMillis = 10)
		scheduler.schedule(UUID.randomUUID(), save(1))
		withTimeout(5_000) { while (saves.isEmpty()) delay(10) }
		scope.coroutineContext[Job]!!.cancel()

		assertEquals(listOf(1), saves)
	}
}
