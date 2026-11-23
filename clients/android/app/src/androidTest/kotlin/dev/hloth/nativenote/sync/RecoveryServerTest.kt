package dev.hloth.nativenote.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.RecoveryPhrase
import dev.hloth.nativenote.model.SetupFailure
import dev.hloth.nativenote.model.SetupResult
import dev.hloth.nativenote.model.SetupStart
import dev.hloth.nativenote.model.SyncStatus
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecoveryServerTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val servers = InstrumentationRegistry.getArguments().getString("syncServers")?.split(',')?.map { entry ->
		entry.split('|').let { (address, apiKey) -> address to apiKey }
	}.orEmpty()

	private fun server(index: Int): Pair<String, String> {
		assumeTrue("run by devtools/android-sync-e2e", servers.size > index)
		return servers[index]
	}

	private fun <T> main(action: suspend () -> T): T = runBlocking { withContext(Dispatchers.Main) { action() } }

	private fun phone(name: String, bodies: List<String> = emptyList()): AppModel {
		val model = appModel(File(folder.root, name).apply { mkdirs() })
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in bodies) model.await { createNote(body.ifEmpty { "$name note" }) }
		onMain { model.select(null) }
		return model
	}

	private fun AppModel.answers(phrase: RecoveryPhrase) = phrase.positionsToConfirm.map { phrase.words[it] }

	private fun AppModel.setUpSync(server: Pair<String, String>): RecoveryPhrase {
		val started = main { prepareSync(server.first, server.second) }
		val phrase = ((started as SetupResult.Ok).value as SetupStart.NewLibrary).phrase
		assertNull(main { finishSync(answers(phrase)) })
		return synced().let { phrase }
	}

	private fun AppModel.join(server: Pair<String, String>, words: List<String>): SetupFailure? {
		assertEquals(SetupResult.Ok(SetupStart.ExistingLibrary), main { prepareSync(server.first, server.second) })
		return main { joinSync(server.first, server.second, entry(words)) }
	}

	private fun AppModel.entry(words: List<String>) = PhraseEntry(mnemonic!!).set(words.joinToString(" "), 0).first

	private fun AppModel.synced(): AppModel {
		await { syncNow() }
		assertEquals(SyncStatus.Phase.Idle, onMain { syncStatus.phase })
		return this
	}

	private fun AppModel.bodies() = onMain { notes }.map { it.body }.sorted()

	@Test
	fun aLibrarySetUpOnOnePhoneJoinsAnotherThroughItsWords() {
		val server = server(6)
		val first = phone("first", RealisticCorpus.bodies(30))
		val phrase = first.setUpSync(server)
		val second = phone("second")

		assertNull(second.join(server, phrase.words))

		assertEquals(first.bodies(), second.synced().bodies())
	}

	@Test
	fun aWipedPhoneRestoresEveryNoteFromTheWordsAndTheApiKey() {
		val server = server(7)
		val phone = phone("phone", RealisticCorpus.bodies(60))
		val before = phone.bodies()
		val phrase = phone.setUpSync(server)

		phone.await { lock() }
		phone.await { erase() }
		phone.await { setUp("a new password") }
		onMain { phone.finishOnboarding() }
		assertEquals(emptyList<String>(), phone.bodies())
		assertNull(phone.join(server, phrase.words))

		assertEquals(before, phone.synced().bodies())
	}

	@Test
	fun afterRotatingOnlyTheNewWordsJoin() {
		val server = server(8)
		val first = phone("first", listOf("Rotated library"))
		val old = first.setUpSync(server)
		val new = (main { first.prepareRotation() } as SetupResult.Ok).value
		assertNull(main { first.finishRotation(first.answers(new)) })
		val second = phone("second")

		assertEquals(SetupFailure.PhraseDoesNotOpen, second.join(server, old.words))
		assertNull(second.join(server, new.words))
		assertEquals(listOf("Rotated library"), second.synced().bodies())
	}

	@Test
	fun aRotationOnAnotherPhoneAsksForTheCurrentWordsFirst() {
		val server = server(9)
		val first = phone("first", listOf("Shared"))
		val phrase = first.setUpSync(server)
		val second = phone("second")
		assertNull(second.join(server, phrase.words))
		val fromSecond = (main { second.prepareRotation() } as SetupResult.Ok).value
		assertNull(main { second.finishRotation(second.answers(fromSecond)) })

		val fromFirst = (main { first.prepareRotation() } as SetupResult.Ok).value
		assertEquals(SetupFailure.RotatedElsewhere, main { first.finishRotation(first.answers(fromFirst)) })
		assertNull(main { first.adoptCurrentPhrase(first.entry(fromSecond.words)) })
		assertNull(main { first.finishRotation(first.answers(fromFirst)) })

		assertNull(phone("third").join(server, fromFirst.words))
	}

	@Test
	fun movingToAnEmptyServerTakesTheLibraryUnderNewWords() {
		val (from, to) = server(10) to server(11)
		val phone = phone("phone", RealisticCorpus.bodies(20))
		phone.setUpSync(from)

		val moved = main { phone.prepareSync(to.first, to.second) }
		val phrase = ((moved as SetupResult.Ok).value as SetupStart.NewLibrary).phrase
		assertNull(main { phone.finishSync(phone.answers(phrase)) })
		phone.synced()

		assertEquals(to.first, onMain { phone.syncStatus.server })
		assertNull(phone("joined").join(to, phrase.words))
	}

	@Test
	fun turningSyncOffAndBackOnReattachesToTheSameLibrary() {
		val server = server(12)
		val phone = phone("phone", listOf("Before turning off"))
		phone.setUpSync(server)

		assertNull(main { phone.turnOffSync() })
		assertEquals(SyncStatus.Phase.Off, onMain { phone.syncStatus.phase })
		phone.await { createNote("While off") }
		assertEquals(SetupResult.Ok(SetupStart.Reattached), main { phone.prepareSync(server.first, server.second) })
		phone.synced()

		val other = phone("other")
		val rotated = (main { phone.prepareRotation() } as SetupResult.Ok).value
		assertNull(main { phone.finishRotation(phone.answers(rotated)) })
		assertNull(other.join(server, rotated.words))
		assertEquals(listOf("Before turning off", "While off"), other.synced().bodies())
	}

	@Test
	fun aServerHoldingAnotherLibraryIsRefused() {
		val (mine, theirs) = server(13) to server(14)
		phone("theirs", listOf("Theirs")).setUpSync(theirs)
		val phone = phone("mine", listOf("Mine"))
		phone.setUpSync(mine)

		assertEquals(SetupResult.Err(SetupFailure.ServerHoldsAnotherLibrary), main { phone.prepareSync(theirs.first, theirs.second) })
		assertEquals(mine.first, onMain { phone.syncStatus.server })
	}
}
