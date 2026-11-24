package dev.hloth.nativenote.model

import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.syncSettings
import dev.hloth.nativenote.support.FakeServer
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncRaceTest {
	private class Hold {
		val entered = CountDownLatch(1)
		private val released = CountDownLatch(1)

		fun run() {
			entered.countDown()
			check(released.await(20, TimeUnit.SECONDS)) { "never released" }
		}

		fun release() = released.countDown()

		fun awaitEntered() = assertTrue(entered.await(10, TimeUnit.SECONDS))
	}

	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val server = FakeServer()
	private val holds = ArrayDeque<Hold>()

	private fun library(vararg bodies: String, syncDelayMillis: Long = 30_000): AppModel {
		val model = appModel(
			folder.root,
			searchNotes = { store, text ->
				synchronized(holds) { holds.removeFirstOrNull() }?.run()
				store.search(text)
			},
			makeTransport = { server },
			syncDelayMillis = syncDelayMillis,
		)
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in bodies) model.await { createNote(body) }
		onMain { model.select(null) }
		model.flush()
		model.await { lock() }
		server.enableSync(folder.root, password)
		model.await { unlock(password) }
		model.await { syncNow() }
		waitUntil { model.syncStatus.phase == SyncStatus.Phase.Idle && model.syncStatus.lastSynced != null }
		return model
	}

	private fun AppModel.flush() = runBlocking { withContext(Dispatchers.Main) { flushPendingSaves() } }

	private fun <T> disk(read: (NoteStore) -> T): T = LibraryFiles(folder.root).let { files ->
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { read(NoteStore(it)) }
	}

	private fun diskBodies() = disk { store -> store.liveNotes().map { it.body }.toSet() }

	private fun AppModel.bodies() = onMain { notes }.map { it.body }.toSet()

	private fun waitUntil(condition: () -> Boolean) {
		val deadline = System.nanoTime() + 15_000_000_000
		while (!onMain(condition)) {
			check(System.nanoTime() < deadline) { "the condition never held" }
			Thread.sleep(20)
		}
	}

	private fun holdWorker(model: AppModel): Hold {
		val hold = Hold()
		synchronized(holds) { holds += hold }
		onMain {
			model.updateSearch("")
			model.updateSearch("hold${holds.size}")
		}
		hold.awaitEntered()
		return hold
	}

	private fun syncUpToItsCommit(model: AppModel): Pair<Job, Hold> {
		val replied = CompletableDeferred<Hold>()
		server.beforeReply = {
			server.beforeReply = {}
			replied.complete(holdWorker(model))
		}
		val syncing = onMain { model.syncNow() }
		val hold = runBlocking { replied.await() }
		Thread.sleep(QUEUED)
		return syncing to hold
	}

	private fun duringTheNextCommit(model: AppModel, action: () -> Unit) {
		val (syncing, hold) = syncUpToItsCommit(model)
		action()
		Thread.sleep(QUEUED)
		hold.release()
		finish(model, syncing)
	}

	private fun finish(model: AppModel, vararg jobs: Job) {
		runBlocking { joinAll(*jobs) }
		onMain { model.updateSearch("") }
		model.flush()
	}

	private fun pullOver(note: Note, body: String, updatedAt: Long = note.updatedAt + 1_000) =
		server.store(Content.Note(note.id, note.createdAt, updatedAt, body), (note.v + 1).toUInt())

	@Test
	fun anEditLeftWhileAPullOfItsNoteCommitsKeepsBothTexts() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		pullOver(note, "from the other device")

		duringTheNextCommit(model) {
			onMain {
				model.select(note.id)
				model.edit(note.id, "typed here", note.v)
				model.select(null)
			}
		}

		waitUntil { model.notes.size == 2 }
		assertEquals(setOf("typed here", "from the other device"), model.bodies())
		assertEquals(setOf("typed here", "from the other device"), diskBodies())
	}

	@Test
	fun anEditLeftWhileItsOwnPushIsAcknowledgedStays() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		onMain { model.edit(note.id, "pushed") }
		model.flush()

		duringTheNextCommit(model) {
			onMain {
				model.select(note.id)
				model.edit(note.id, "typed since")
				model.select(null)
			}
		}

		assertEquals(setOf("typed since"), model.bodies())
		assertEquals(setOf("typed since"), diskBodies())
	}

	@Test
	fun aKeystrokeFromBeforeAPullNeverOverwritesThePulledText() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		pullOver(note, "from the other device")
		model.await { syncNow() }
		assertEquals(setOf("from the other device"), model.bodies())

		onMain {
			model.select(note.id)
			model.edit(note.id, "Draft and a late key", note.v)
		}
		model.flush()

		waitUntil { model.notes.size == 2 }
		assertEquals(setOf("from the other device", "Draft and a late key"), model.bodies())
		assertEquals(setOf("from the other device", "Draft and a late key"), diskBodies())
		assertEquals("Draft and a late key", onMain { model.selectedNote?.body })
	}

	@Test
	fun textTypedOnAPulledNoteStaysWhenAnEarlierSaveBecomesItsCopy() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		pullOver(note, "from the other device")
		val (syncing, first) = syncUpToItsCommit(model)
		onMain {
			model.select(note.id)
			model.edit(note.id, "typed here", note.v)
		}
		val second = Hold()
		synchronized(holds) { holds += second }
		onMain { model.updateSearch("second") }
		val flushing = CoroutineScope(Dispatchers.Main).launch { model.flushPendingSaves() }
		Thread.sleep(QUEUED)

		first.release()
		waitUntil { model.notes.single().body == "from the other device" }
		onMain { model.edit(note.id, "from the other device, and more", note.v + 1) }
		val answered = CompletableDeferred<Unit>()
		server.beforeReply = { answered.await() }
		second.release()
		runBlocking { flushing.join() }
		model.flush()
		waitUntil { model.notes.size == 2 }
		assertEquals(setOf("typed here", "from the other device, and more"), model.bodies())
		assertEquals(setOf("typed here", "from the other device, and more"), diskBodies())

		answered.complete(Unit)
		finish(model, syncing)
		assertEquals(setOf("typed here", "from the other device, and more"), model.bodies())
	}

	@Test
	fun aPulledNoteNeverTakesThePlaceOfAnEditThatCouldNotBeSaved() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		pullOver(note, "from the other device", updatedAt = System.currentTimeMillis() + 3_600_000)
		disk { it.connection.execute("CREATE TRIGGER poison BEFORE INSERT ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END") }
		val (syncing, hold) = syncUpToItsCommit(model)
		onMain { model.edit(note.id, "poison typed here", note.v) }
		val flushing = CoroutineScope(Dispatchers.Main).launch { model.flushPendingSaves() }
		Thread.sleep(QUEUED)
		hold.release()
		runBlocking { joinAll(syncing, flushing) }
		waitUntil { model.failure is Failure.Unsaved }

		disk { it.connection.execute("DROP TRIGGER poison") }
		onMain { model.updateSearch("") }

		waitUntil { model.notes.size == 2 }
		assertEquals(setOf("poison typed here", "from the other device"), model.bodies())
		assertEquals(setOf("poison typed here", "from the other device"), diskBodies())
	}

	@Test
	fun aCopyReadWhenTheLibraryLocksIsNotShown() {
		val model = library("Draft")
		val note = onMain { model.notes.single() }
		pullOver(note, "from the other device")
		model.await { syncNow() }

		val first = holdWorker(model)
		onMain { model.edit(note.id, "late key", note.v) }
		val saving = CoroutineScope(Dispatchers.Main).launch { model.flushPendingSaves() }
		Thread.sleep(QUEUED)
		val second = Hold()
		synchronized(holds) { holds += second }
		onMain { model.updateSearch("again") }
		first.release()
		second.awaitEntered()
		Thread.sleep(QUEUED)
		val locking = onMain { model.lock() }
		second.release()
		runBlocking { joinAll(saving, locking) }

		assertEquals(emptyList<Note>(), onMain { model.notes })
		model.await { unlock(password) }
		assertEquals(setOf("from the other device", "late key"), model.bodies())
	}

	@Test
	fun aPullAndAnAcknowledgmentReachAnActiveSearch() {
		val model = library("Groceries")
		onMain { model.updateSearch("kayak") }
		val id = UUID.randomUUID()
		server.store(Content.Note(id, 1, 1, "Kayak rental"), 1u)

		model.await { syncNow() }

		waitUntil { model.results() == listOf("Kayak rental") }
	}

	@Test
	fun turningSyncOffWhileAPulledSearchRunsReportsNothing() {
		val model = library("Kayak rental")
		onMain { model.updateSearch("kayak") }
		waitUntil { model.results().size == 1 }
		server.store(Content.Note(UUID.randomUUID(), 1, 1, "Another kayak"), 1u)
		val hold = Hold()
		synchronized(holds) { holds += hold }

		val syncing = onMain { model.syncNow() }
		hold.awaitEntered()
		val off = CoroutineScope(Dispatchers.Main).launch { model.turnOffSync() }
		Thread.sleep(QUEUED)
		hold.release()
		runBlocking { joinAll(syncing, off) }

		assertNull(onMain { model.failure })
		assertEquals(setOf("Kayak rental", "Another kayak"), onMain { model.results().toSet() })
	}

	@Test
	fun turningSyncOffOutlivesTheScreenThatAskedForIt() {
		val model = library("Note")
		val answered = CompletableDeferred<Unit>()
		server.beforeReply = { withContext(NonCancellable) { answered.await() } }
		onMain { model.syncNow() }
		waitUntil { model.syncStatus.phase == SyncStatus.Phase.Syncing }
		Thread.sleep(QUEUED)
		assertEquals(SyncStatus.Phase.Syncing, onMain { model.syncStatus.phase })

		val screen = CoroutineScope(Dispatchers.Main).launch { model.turnOffSync() }
		Thread.sleep(QUEUED)
		assertTrue(screen.isActive)
		runBlocking { screen.cancelAndJoin() }
		answered.complete(Unit)
		waitUntil { model.syncStatus.phase == SyncStatus.Phase.Off }
		for (attempt in 1..200) if (disk { it.syncSettings() } != null) Thread.sleep(20)
		model.await { lock() }
		model.await { unlock(password) }

		assertEquals(SyncStatus.Phase.Off, onMain { model.syncStatus.phase })
		assertNull(disk { it.syncSettings() })
	}

	@Test
	fun leavingChangeServerWhileItIsStoredStillMovesToTheStoredServer() {
		val model = library("Note")
		server.blobVersion = 1u
		val asked = CountDownLatch(1)
		server.beforeReply = { request -> if (request is Request.Sync) asked.countDown() }
		disk { it.connection.execute(SLOW_SERVER_CHANGE) }

		val changing = CoroutineScope(Dispatchers.Main).launch { model.prepareSync(NEW_ADDRESS, server.apiKeyHex) }
		assertTrue(asked.await(10, TimeUnit.SECONDS))
		Thread.sleep(QUEUED)
		onMain {
			changing.cancel()
			model.cancelRecovery()
		}
		runBlocking { changing.join() }
		waitUntil { model.syncStatus.phase == SyncStatus.Phase.Idle && model.syncStatus.server == NEW_ADDRESS }

		assertNull(onMain { model.failure })
		assertEquals(disk { it.syncSettings()!!.server }, onMain { model.syncStatus.server })
	}

	@Test
	fun lockingDuringTheSaveOfSharedTextKeepsIt() {
		val model = library("Note")
		onMain {
			model.createNote("Shared\ntext")
			Handler(Looper.getMainLooper()).post { model.lock() }
		}
		waitUntil { model.phase == AppModel.Phase.Locked }
		model.await { lock() }
		model.await { unlock(password) }

		assertTrue("Shared\ntext" in model.bodies())
	}

	@Test
	fun sharedTextIsPushedWithoutWaitingForAnEdit() {
		val model = library("Note", syncDelayMillis = 50)
		val before = server.requests

		onMain { model.requestNote("Shared") }

		waitUntil { server.requests > before && "Shared" in server.bodies() }
	}

	private fun AppModel.results() =
		groups(NoteGrouping(0, ZoneId.of("UTC"), NoteGrouping.Words("", "", "", { day, time -> "$day $time" }, DateTimeFormatter.ISO_TIME, Locale.US)), "Results")
			.flatMap { group -> group.notes.map { it.title } }

	private companion object {
		const val QUEUED = 400L
		const val NEW_ADDRESS = "http://127.0.0.1:10/"
		const val SLOW_SERVER_CHANGE = "CREATE TRIGGER slow BEFORE INSERT ON meta WHEN new.k = 'apiKey' BEGIN " +
			"INSERT INTO meta SELECT 'slow', zeroblob(1) FROM (WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE x < 8000000) SELECT count(*) AS c FROM n) WHERE c < 0; END"
	}
}
