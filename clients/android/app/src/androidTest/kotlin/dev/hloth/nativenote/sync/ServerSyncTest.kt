package dev.hloth.nativenote.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServerSyncTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val contentKey = AesGcm.randomBytes(32)
	private val servers = InstrumentationRegistry.getArguments().getString("syncServers")?.split(',')?.map { entry ->
		entry.split('|').let { (address, apiKey) -> address to EnvelopeKey.apiKey(apiKey)!! }
	}.orEmpty()

	private fun server(index: Int): Pair<String, ByteArray> {
		assumeTrue("run by devtools/android-sync-e2e", servers.size > index)
		return servers[index]
	}

	private fun phone(name: String, server: Pair<String, ByteArray>, bodies: List<String> = emptyList(), contentKey: ByteArray = this.contentKey): AppModel {
		val directory = File(folder.root, name).apply { mkdirs() }
		val files = LibraryFiles(directory)
		val model = appModel(directory)
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		model.await { lock() }
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { connection ->
			val store = NoteStore(connection)
			store.enableSync(SyncSettings(server.first, server.second, contentKey), 0u)
			connection.transaction {
				bodies.forEachIndexed { index, body ->
					store.put(Note(UUID.randomUUID(), body.ifEmpty { "$name note $index" }, 1_786_000_000_000 + index, 1_786_000_000_000 + index, dirty = true), pulled = false)
				}
			}
		}
		model.await { unlock(password) }
		return model
	}

	private fun AppModel.synced(): AppModel {
		await { syncNow() }
		val status = onMain { syncStatus }
		assertEquals("$status", SyncStatus.Phase.Idle, status.phase)
		assertEquals("$status", emptyList<SyncProblem>(), status.problems)
		return this
	}

	private fun AppModel.contents() = onMain { notes }.map { listOf(it.id, it.body, it.createdAt, it.updatedAt) }.sortedBy { it[0].toString() }

	private fun AppModel.bodies() = onMain { notes }.map { it.body }.sorted()

	private fun AppModel.idOf(body: String) = onMain { notes.single { it.body == body }.id }

	@Test
	fun twoPhonesConvergeOnARealisticLibraryWithEditsAndDeletes() {
		val server = server(0)
		val first = phone("first", server, RealisticCorpus.bodies(60)).synced()
		val second = phone("second", server).synced()
		assertEquals(60, second.contents().size)
		assertEquals(first.contents(), second.contents())

		val edited = onMain { second.notes.first { it.title == "Shopping" }.id }
		val deleted = onMain { second.notes.first { it.title == "Ideas" }.id }
		onMain { second.edit(edited, "Shopping\nedited on the second phone") }
		runBlocking { onMain { second.delete(deleted) }.await() }
		second.await { createNote("Written on the second phone") }
		second.synced()
		first.synced()

		assertEquals(second.contents(), first.contents())
		assertEquals("Shopping\nedited on the second phone", onMain { first.notes.single { it.id == edited }.body })
		assertTrue(onMain { first.notes.none { it.id == deleted } })
		assertTrue(first.bodies().contains("Written on the second phone"))
	}

	@Test
	fun concurrentEditsKeepBothTexts() {
		val server = server(1)
		val first = phone("first", server, listOf("Plan\nshared")).synced()
		val second = phone("second", server).synced()
		val id = first.idOf("Plan\nshared")

		onMain { first.edit(id, "Plan\nfrom the first phone") }
		onMain { second.edit(id, "Plan\nfrom the second phone") }
		first.synced()
		second.synced()
		first.synced()

		val expected = listOf("Plan\nfrom the first phone", "Plan\nfrom the second phone")
		assertEquals(expected, second.bodies())
		assertEquals(expected, first.bodies())
		assertEquals("Plan\nfrom the first phone", onMain { second.notes.single { it.id == id }.body })
	}

	@Test
	fun aThousandNotesTravelInSeveralRequests() {
		val server = server(2)
		val first = phone("first", server, RealisticCorpus.bodies(1_000)).synced()
		val second = phone("second", server).synced()

		assertEquals(1_000, second.contents().size)
		assertEquals(first.contents(), second.contents())
	}

	@Test
	fun lockingDuringASyncStopsItAndTheEditsPushAfterUnlocking() {
		val server = server(3)
		val first = phone("first", server, RealisticCorpus.bodies(300))
		val started = System.nanoTime()
		first.await { lock() }
		assertTrue("the lock waited ${(System.nanoTime() - started) / 1_000_000} ms", System.nanoTime() - started < 5_000_000_000)

		first.await { unlock(password) }
		first.synced()
		assertEquals(300, phone("second", server).synced().contents().size)
	}

	@Test
	fun aWrongApiKeyIsRefused() {
		val (address, _) = server(4)
		val phone = phone("wrong", address to AesGcm.randomBytes(32), listOf("Never leaves"))

		phone.await { syncNow() }

		val phase = onMain { phone.syncStatus.phase }
		assertTrue("$phase", phase is SyncStatus.Phase.Failed && (phase.reason is SyncError.Unopenable || (phase.reason as? SyncError.Refused)?.status == 400))
	}

	@Test
	fun anUnreachableServerFails() {
		val phone = phone("unreachable", "http://127.0.0.1:9/" to AesGcm.randomBytes(32), listOf("Waits"))

		phone.await { syncNow() }

		val phase = onMain { phone.syncStatus.phase }
		assertTrue("$phase", phase is SyncStatus.Phase.Failed && phase.reason is IOException)
	}

	@Test
	fun anotherLibrarysChangesAreSkippedAsUnreadable() {
		val server = server(5)
		phone("other", server, listOf("Someone else's note"), contentKey = AesGcm.randomBytes(32)).synced()
		val phone = phone("mine", server)

		val deadline = System.nanoTime() + 10_000_000_000
		while (onMain { phone.syncStatus.lastSynced } == null) {
			check(System.nanoTime() < deadline) { "the first sync never finished: ${onMain { phone.syncStatus }}" }
			Thread.sleep(20)
		}

		assertEquals(listOf(SyncProblem.UnverifiableChange), onMain { phone.syncStatus.problems })
		assertEquals(emptyList<String>(), phone.bodies())
	}
}
