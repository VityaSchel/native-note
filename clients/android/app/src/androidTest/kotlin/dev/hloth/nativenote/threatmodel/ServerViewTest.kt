package dev.hloth.nativenote.threatmodel

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.conformance.RequestDecoding
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.SetupResult
import dev.hloth.nativenote.model.SetupStart
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.Schema
import dev.hloth.nativenote.storage.commit
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.storage.syncSettings
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.EnvelopeKey
import dev.hloth.nativenote.sync.HttpTransport
import dev.hloth.nativenote.sync.NoteCipher
import dev.hloth.nativenote.sync.Padding
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.Response
import dev.hloth.nativenote.sync.Status
import dev.hloth.nativenote.sync.SyncConnection
import dev.hloth.nativenote.sync.SyncEngine
import dev.hloth.nativenote.sync.SyncProblem
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.sync.Write
import dev.hloth.nativenote.sync.bytes
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServerViewTest {
	@get:Rule
	val folder = TemporaryFolder()

	private class Recorder(private val transport: SyncTransport, private val exchanges: MutableList<Pair<ByteArray, ByteArray>>) : SyncTransport {
		override suspend fun post(body: ByteArray): ByteArray = transport.post(body).also { exchanges += body to it }
	}

	private class Library(val model: AppModel, val settings: SyncSettings, val exchanges: List<Pair<ByteArray, ByteArray>>, val ids: List<UUID>)

	private val password = "correct horse"
	private val secrets = listOf("quartzite zephyr alpha", "jacaranda meridian beta", "obsidian lattice gamma")
	private val servers = InstrumentationRegistry.getArguments().getString("syncServers")?.split(',')?.map { entry ->
		entry.split('|').let { (address, apiKey) -> address to apiKey }
	}.orEmpty()

	private fun server(index: Int): Pair<String, String> {
		assumeTrue("run by devtools/android-sync-e2e", servers.size > index)
		return servers[index]
	}

	private fun <T> main(action: suspend () -> T): T = runBlocking { withContext(Dispatchers.Main) { action() } }

	private fun library(server: Pair<String, String>): Library {
		val directory = File(folder.root, "library").apply { mkdirs() }
		val exchanges = Collections.synchronizedList(mutableListOf<Pair<ByteArray, ByteArray>>())
		val model = appModel(directory, makeTransport = { address -> Recorder(HttpTransport(address), exchanges) })
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in secrets) model.await { createNote(body) }
		onMain { model.select(null) }
		val phrase = ((main { model.prepareSync(server.first, server.second) } as SetupResult.Ok).value as SetupStart.NewLibrary).phrase
		assertNull(main { model.finishSync(phrase.positionsToConfirm.map { phrase.words[it] }) })
		model.await { syncNow() }
		val files = LibraryFiles(directory)
		val settings = SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { NoteStore(it).syncSettings()!! }
		return Library(model, settings, exchanges, onMain { model.notes.map { it.id } })
	}

	private fun clearValues(library: Library): List<ByteArray> {
		val cipher = NoteCipher(library.settings.contentKey)
		return secrets.map { it.encodeToByteArray() } + library.ids.map { it.bytes() } + library.ids.map(cipher::blindedId)
	}

	private fun ByteArray.holds(needle: ByteArray) = (0..size - needle.size).any { start -> needle.indices.all { this[start + it] == needle[it] } }

	private fun requests(library: Library, apiKey: ByteArray): List<Request> = library.exchanges.toList().mapNotNull { (request, _) ->
		EnvelopeKey.fromApiKey(apiKey).open(request, ByteArray(0))?.let { runCatching { RequestDecoding.decode(it) }.getOrNull() }
	}

	@Test
	fun everyEnvelopeOnTheWireIsBucketSizedAndHoldsNothingInTheClear() {
		val library = library(server(16))
		val buckets = generateSequence(256) { it * 2 }.takeWhile { it <= Padding.BODY_MAX }.toSet()

		assertTrue(library.exchanges.size >= 3)
		for ((request, reply) in library.exchanges.toList()) {
			for (body in listOf(request, reply)) {
				assertTrue("${body.size}", body.size - AesGcm.NONCE_LENGTH - 16 in buckets)
				for (value in clearValues(library)) assertFalse(body.holds(value))
			}
		}
	}

	@Test
	fun aLeakedAPIKeyOpensCapturedEnvelopesToMetadataButNotToNotes() {
		val library = library(server(17))
		val writes = requests(library, library.settings.apiKey).filterIsInstance<Request.Sync>().flatMap { it.writes }
		val cipher = NoteCipher(library.settings.contentKey)

		assertEquals(library.ids.map { cipher.blindedId(it).toList() }.toSet(), writes.map { it.blindedId.toList() }.toSet())
		assertTrue(writes.all { it.v == 1u })
		val guess = NoteCipher(AesGcm.randomBytes(32))
		for (write in writes) {
			assertNull(guess.open(write))
			assertNotNull(cipher.open(write))
			for (secret in secrets) assertFalse(write.payload.holds(secret.encodeToByteArray()))
		}
	}

	@Test
	fun theServerSeesEachNotesVersionCountAndNothingElseOfIt() {
		val library = library(server(18))
		val edited = library.ids.first()
		for (round in 1..4) {
			onMain { library.model.edit(edited, "edited $round times") }
			library.model.await { syncNow() }
		}

		val serverOperator = SyncConnection(library.settings.apiKey, HttpTransport(library.settings.server))
		val changes = (runBlocking { serverOperator.send(Request.Sync(0u, emptyList())) } as Response.Sync).changes

		val seen = changes.single { it.blindedId.contentEquals(NoteCipher(library.settings.contentKey).blindedId(edited)) }
		assertEquals(5u, seen.v)
		assertFalse(seen.payload.holds("edited 4 times".encodeToByteArray()))
		assertTrue(changes.all { it.payload.size % Content.BLOCK == 28 })
	}

	@Test
	fun theContentAndAPIKeysAloneReadEveryNote() {
		val library = library(server(19))
		val stolen = library.settings

		val bodies = SQLiteConnection(File(folder.root, "thief.db"), AesGcm.randomBytes(32)).use { connection ->
			Schema.prepare(connection)
			val store = NoteStore(connection)
			store.enableSync(stolen, 1u)
			runBlocking { SyncEngine(store, stolen, HttpTransport(stolen.server), Dispatchers.IO).sync { store.commit(it) } }
			store.liveNotes().map { it.body }.toSet()
		}

		assertEquals(secrets.toSet(), bodies)
	}

	@Test
	fun aStolenAPIKeyForgesWritesThatNoPhoneApplies() {
		val library = library(server(20))
		val attacker = SyncConnection(library.settings.apiKey, HttpTransport(library.settings.server))
		val real = (runBlocking { attacker.send(Request.Sync(0u, emptyList())) } as Response.Sync).changes.first()

		val forged = listOf(
			Write(real.blindedId, real.v + 1u, ByteArray(16), ByteArray(Content.BLOCK + 28) { 7 }),
			Write(ByteArray(16) { 9 }, 1u, ByteArray(16), ByteArray(Content.BLOCK + 28) { 7 }),
		)
		val results = (runBlocking { attacker.send(Request.Sync(0u, forged)) } as Response.Sync).results
		assertEquals(listOf(Status.Accepted, Status.Accepted), results.map { it.status })

		library.model.await { syncNow() }

		assertEquals(listOf(SyncProblem.UnverifiableChange), onMain { library.model.syncStatus.problems })
		assertEquals(secrets.toSet(), onMain { library.model.notes.map { it.body }.toSet() })
	}
}
