package dev.hloth.nativenote.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.R
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockRecordFile
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryModelTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val files get() = LibraryFiles(folder.root)

	private fun unlocked(): AppModel {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		return model
	}

	private fun <T> disk(read: (NoteStore) -> T): T =
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { read(NoteStore(it)) }

	private fun AppModel.newNote(): UUID {
		await { createNote() }
		return onMain { selection!! }
	}

	private fun AppModel.flush() = runBlocking { withContext(Dispatchers.Main) { flushPendingSaves() } }

	private fun AppModel.titles() = onMain { groups(grouping(), "Results").flatMap { group -> group.notes.map { it.title } } }

	private fun grouping() = NoteGrouping(
		System.currentTimeMillis(),
		ZoneId.systemDefault(),
		NoteGrouping.Words("Today", "Yesterday", "Previous 7 Days", { day, time -> "$day at $time" }, DateTimeFormatter.ofPattern("HH:mm"), Locale.US),
	)

	private fun waitUntil(condition: () -> Boolean) {
		val deadline = System.nanoTime() + 10_000_000_000
		while (!condition()) {
			check(System.nanoTime() < deadline) { "the condition never held" }
			Thread.sleep(20)
		}
	}

	private fun poison() = disk {
		it.connection.execute("CREATE TRIGGER poison BEFORE UPDATE ON note WHEN new.body LIKE '%poison%' BEGIN SELECT RAISE(ABORT, 'poisoned'); END")
	}

	private fun cure() = disk { it.connection.execute("DROP TRIGGER poison") }

	@Test
	fun aNewNoteIsSelectedAsksTheEditorForFocusAndClearsTheSearch() {
		val model = unlocked()
		onMain { model.updateSearch("kayak") }

		val id = model.newNote()

		onMain {
			assertEquals(id, model.focusesEditor)
			assertEquals("", model.searchText)
			assertEquals(listOf(id), model.notes.map { it.id })
			model.editorTookFocus()
			assertNull(model.focusesEditor)
		}
		assertFalse(disk { it.note(id)!!.dirty })
	}

	@Test
	fun aNewNoteLeftEmptyLeavesNoTrace() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "  \n\t") }

		onMain { model.select(null) }
		model.flush()

		onMain { assertEquals(emptyList<Note>(), model.notes) }
		waitUntil { disk { it.note(id) } == null }
	}

	@Test
	fun aNewNoteLeftEmptyIsGoneAfterLockingAndTheLibraryCloses() {
		val model = unlocked()
		val id = model.newNote()

		model.await { lock() }

		assertNull(disk { it.note(id) })
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), folder.root.list()!!.sorted())
	}

	@Test
	fun aNoteWithTextSurvivesLockingAndUnlocking() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "Groceries\nmilk") }

		model.await { lock() }
		assertEquals("Groceries\nmilk", disk { it.note(id)!!.body })
		model.await { unlock(password) }

		assertEquals(listOf("Groceries"), model.titles())
		onMain { assertNull(model.selection) }
	}

	@Test
	fun anEditSavesOnItsOwnWithoutLeavingTheNote() {
		val model = unlocked()
		val id = model.newNote()

		onMain { model.edit(id, "typed and left alone") }

		waitUntil { disk { it.note(id)!!.body } == "typed and left alone" }
		assertTrue(disk { it.note(id)!!.dirty })
		assertEquals(0L, disk { it.note(id)!!.v })
	}

	@Test
	fun editingWithTheSameTextChangesNothing() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "same") }
		model.flush()
		val saved = onMain { model.notes.single() }

		onMain { model.edit(id, "same") }

		onMain { assertTrue(saved === model.notes.single()) }
	}

	@Test
	fun theEditedNoteMovesToTheTopWithTheOthersIntact() {
		val model = unlocked()
		val first = model.newNote()
		onMain { model.edit(first, "first") }
		val second = model.newNote()
		onMain { model.edit(second, "second") }
		onMain { model.select(first) }
		Thread.sleep(5)

		onMain { model.edit(first, "first, edited") }
		model.await { lock() }
		model.await { unlock(password) }

		assertEquals(listOf("first, edited", "second"), model.titles())
	}

	@Test
	fun deletingTheOpenNoteClosesItAndLeavesATombstone() {
		val model = unlocked()
		val kept = model.newNote()
		onMain { model.edit(kept, "kept") }
		val doomed = model.newNote()
		onMain { model.edit(doomed, "doomed") }

		val deleted = onMain { model.delete(doomed) }

		assertTrue(runBlocking { deleted.await() })
		onMain { assertNull(model.selection) }
		assertEquals(listOf("kept"), model.titles())
		val tombstone = disk { it.note(doomed)!! }
		assertTrue(tombstone.deleted)
		assertEquals("", tombstone.body)
		assertEquals("kept", disk { it.note(kept)!!.body })
	}

	@Test
	fun aSearchFiltersByRelevanceAndClearingItRestoresEveryNote() {
		val model = unlocked()
		for (body in listOf("Trip\nkayak", "Kayak log\nkayak kayak kayak", "Groceries\nmilk")) {
			val id = model.newNote()
			onMain { model.edit(id, body) }
		}
		onMain { model.select(null) }
		model.flush()

		onMain { model.updateSearch("kayak") }
		waitUntil { model.titles() == listOf("Kayak log", "Trip") }
		onMain { model.updateSearch("absent") }
		waitUntil { model.titles().isEmpty() }

		onMain { model.updateSearch("") }
		assertEquals(setOf("Trip", "Kayak log", "Groceries"), model.titles().toSet())
	}

	@Test
	fun lockingKeepsTheSearchAndUnlockingRerunsIt() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "Trip\nkayak") }
		model.flush()
		onMain { model.updateSearch("kayak") }
		waitUntil { model.titles() == listOf("Trip") }

		model.await { lock() }
		model.await { unlock(password) }

		onMain { assertEquals("kayak", model.searchText) }
		assertEquals(listOf("Trip"), model.titles())
	}

	@Test
	fun aFailedSearchShowsNothingIsReportedOnceAndRecovers() {
		var failing = false
		val model = appModel(folder.root, searchNotes = { store, text -> if (failing) error("search broke") else store.search(text) })
		model.await { start() }
		model.await { setUp(password) }
		val id = model.newNote()
		onMain { model.edit(id, "kayak") }
		model.flush()
		failing = true

		onMain { model.updateSearch("ka") }
		waitUntil { onMain { model.failure } != null }
		onMain {
			assertEquals(R.string.failure_search, (model.failure as Failure.Unexpected).title)
			model.dismissFailure()
			model.updateSearch("kay")
		}
		waitUntil { model.titles().isEmpty() }
		Thread.sleep(200)
		onMain { assertNull(model.failure) }

		failing = false
		onMain { model.updateSearch("kaya") }
		waitUntil { model.titles() == listOf("kayak") }
	}

	@Test
	fun aFailedSaveIsReportedOnceRetriedAndClearsWhenItLands() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "first") }
		model.flush()
		poison()

		onMain { model.edit(id, "poison pill") }
		assertFalse(model.flush())
		val reported = onMain { model.failure }
		assertTrue(reported is Failure.Unsaved)
		onMain { model.dismissFailure() }
		assertFalse(model.flush())
		onMain { assertNull(model.failure) }

		cure()
		waitUntil { disk { it.note(id)!!.body } == "poison pill" }
		assertTrue(model.flush())
		onMain { assertNull(model.failure) }
	}

	@Test
	fun lockingWithAFailingSaveKeepsItsTextUntilItLandsAfterUnlocking() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "first") }
		model.flush()
		poison()

		onMain { model.edit(id, "poison typed before locking") }
		model.await { lock() }
		assertTrue(onMain { model.failure } is Failure.Unsaved)
		assertTrue(files.database.resolveSibling("notes.db-wal").exists())

		model.await { unlock(password) }
		onMain { assertEquals("poison typed before locking", model.notes.single().body) }
		assertTrue(onMain { model.failure } is Failure.Unsaved)
		cure()

		waitUntil { disk { it.note(id)!!.body } == "poison typed before locking" }
		waitUntil { onMain { model.failure } == null }
		model.await { lock() }
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), folder.root.list()!!.sorted())
	}

	@Test
	fun aFailedDeleteKeepsTheNoteAndSaysWhy() {
		val model = unlocked()
		val id = model.newNote()
		onMain { model.edit(id, "kept") }
		model.flush()
		disk { it.connection.execute("CREATE TRIGGER refuse BEFORE UPDATE OF deleted ON note BEGIN SELECT RAISE(ABORT, 'refused'); END") }

		val deleted = onMain { model.delete(id) }

		assertFalse(runBlocking { deleted.await() })
		assertEquals(listOf("kept"), model.titles())
		assertEquals(R.string.failure_delete, (onMain { model.failure } as Failure.Unexpected).title)
	}

	@Test
	fun aThousandNoteLibraryLoadsNewestFirst() {
		val model = unlocked()
		val bodies = RealisticCorpus.bodies(1_000)
		disk { store ->
			store.connection.transaction {
				bodies.forEachIndexed { index, body -> store.put(Note(UUID.randomUUID(), body, index.toLong(), index.toLong(), dirty = true), pulled = false) }
			}
		}
		model.await { lock() }

		model.await { unlock(password) }

		onMain {
			assertEquals(1_000, model.notes.size)
			assertEquals(bodies.last(), model.notes.first().body)
			assertNotNull(model.groups(grouping(), "Results").singleOrNull())
		}
	}
}
