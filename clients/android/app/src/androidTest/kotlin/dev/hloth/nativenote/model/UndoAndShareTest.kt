package dev.hloth.nativenote.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UndoAndShareTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val files get() = LibraryFiles(folder.root)

	private fun unlocked(vararg bodies: String): AppModel {
		val model = appModel(folder.root)
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in bodies) {
			model.await { createNote() }
			onMain { model.edit(model.selection!!, body) }
		}
		return model
	}

	private fun <T> disk(read: (NoteStore) -> T): T =
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use { read(NoteStore(it)) }

	private fun AppModel.flush() = runBlocking { withContext(Dispatchers.Main) { flushPendingSaves() } }

	private fun AppModel.deleted(id: UUID) = runBlocking { onMain { delete(id) }.await() }

	private fun AppModel.titles() = onMain {
		groups(NoteGrouping(0, ZoneId.of("UTC"), NoteGrouping.Words("", "", "", { d, t -> "$d $t" }, DateTimeFormatter.ISO_TIME, Locale.US)), "Results")
			.flatMap { group -> group.notes.map { it.title } }
	}

	private fun waitUntil(condition: () -> Boolean) {
		val deadline = System.nanoTime() + 10_000_000_000
		while (!condition()) {
			check(System.nanoTime() < deadline) { "the condition never held" }
			Thread.sleep(20)
		}
	}

	@Test
	fun aDeletedNoteComesBackAsANewNoteWithItsUnsavedTextAndItsTimes() {
		val model = unlocked("Draft\nfirst")
		val id = onMain { model.selection!! }
		onMain { model.edit(id, "Draft\ntyped just before deleting") }
		val original = onMain { model.notes.single() }
		val kept = onMain { model.keepForUndo(id) }!!

		assertTrue(model.deleted(id))
		val restored = onMain { model.restore(kept) }!!

		assertNotEquals(id, restored)
		val note = onMain { model.notes.single() }
		assertEquals(restored, note.id)
		assertEquals(restored, onMain { model.selection })
		assertEquals("Draft\ntyped just before deleting", note.body)
		assertEquals(original.createdAt, note.createdAt)
		assertEquals(original.updatedAt, note.updatedAt)
		assertArrayEquals(original.ext, note.ext)
		model.flush()
		assertEquals(note.body, disk { it.note(restored)!!.body })
		assertTrue(disk { it.note(id)!!.deleted })
	}

	@Test
	fun nothingComesBackWhileTheOriginalStillLivesOrAfterLocking() {
		val model = unlocked("Alive")
		val id = onMain { model.selection!! }
		val kept = onMain { model.keepForUndo(id) }!!

		assertNull(onMain { model.restore(kept) })

		model.deleted(id)
		model.await { lock() }
		model.await { unlock(password) }
		assertNull(onMain { model.restore(kept) })
		assertEquals(emptyList<String>(), model.titles())
	}

	@Test
	fun deletingARestoredNoteBeforeItsSaveLandsLeavesNothingOnDisk() {
		val model = unlocked("deleted twice")
		val id = onMain { model.selection!! }
		val kept = onMain { model.keepForUndo(id) }!!
		model.deleted(id)
		val restored = onMain { model.restore(kept) }!!

		model.deleted(restored)
		model.flush()

		assertEquals(emptyList<String>(), disk { store -> store.liveNotes().map { it.title } })
		assertTrue(disk { store -> store.pendingPushes().none { it.id == restored } })
		model.await { lock() }
		model.await { unlock(password) }
		assertEquals(emptyList<String>(), model.titles())
	}

	@Test
	fun undoRightAfterDeleteRestoresBeforeTheTombstoneLands() {
		val model = unlocked("quick undo")
		val id = onMain { model.selection!! }
		val kept = onMain { model.keepForUndo(id) }!!

		val restored = onMain {
			model.delete(id)
			model.restore(kept)
		}

		assertNotNull(restored)
		assertEquals(listOf("quick undo"), onMain { model.notes.map { it.body } })
	}

	@Test
	fun aRestoredNoteTakesItsPlaceInTheSearchResultsOrJoinsALaterSearch() {
		val model = unlocked("Kayak trip", "Kayak log\nkayak kayak")
		onMain { model.select(null) }
		model.flush()
		onMain { model.updateSearch("kayak") }
		waitUntil { model.titles() == listOf("Kayak log", "Kayak trip") }
		val trip = onMain { model.notes.single { it.title == "Kayak trip" }.id }
		val kept = onMain { model.keepForUndo(trip) }!!
		model.deleted(trip)
		waitUntil { model.titles() == listOf("Kayak log") }

		onMain { model.restore(kept) }
		assertEquals(listOf("Kayak log", "Kayak trip"), model.titles())

		val log = onMain { model.notes.single { it.title == "Kayak log" }.id }
		val keptLog = onMain { model.keepForUndo(log) }!!
		model.deleted(log)
		onMain { model.updateSearch("log") }
		waitUntil { model.titles().isEmpty() }
		onMain { model.restore(keptLog) }
		waitUntil { model.titles() == listOf("Kayak log") }
	}

	@Test
	fun aSharedTextWaitsForTheUnlockThenOpensAsANewNote() {
		val model = unlocked()
		model.await { lock() }

		onMain { model.requestNote("Shared title\nhttps://example.com") }
		assertEquals(emptyList<String>(), model.titles())
		model.await { unlock(password) }
		waitUntil { onMain { model.notes.size } == 1 }

		val note = onMain { model.notes.single() }
		assertEquals("Shared title\nhttps://example.com", note.body)
		assertEquals(note.id, onMain { model.selection })
		assertEquals(note.id, onMain { model.focusesEditor })
		model.flush()
		assertTrue(disk { it.note(note.id)!!.dirty })
	}

	@Test
	fun aNoteRequestedWhileUnlockedOpensAtOnceAndAnEmptyOneIsDiscardedWhenLeft() {
		val model = unlocked()

		onMain { model.requestNote("") }
		waitUntil { onMain { model.selection } != null }
		val id = onMain { model.selection!! }
		onMain { model.select(null) }

		waitUntil { onMain { model.notes.isEmpty() } }
		waitUntil { disk { it.note(id) } == null }
	}

	@Test
	fun leavingBeforeUnlockingForgetsTheSharedText() {
		val model = unlocked()
		model.await { lock() }
		onMain { model.requestNote("never saved") }

		onMain { model.appStopped() }
		model.await { unlock(password) }

		assertEquals(emptyList<String>(), model.titles())
	}
}
