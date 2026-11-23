package dev.hloth.nativenote.storage

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.sync.bytes
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NoteStoreTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val key = ByteArray(32) { (it * 7 + 5).toByte() }
	private val opened = mutableListOf<SQLiteConnection>()

	private fun connection() = SQLiteConnection(File(folder.root, "notes.db"), key).also {
		Schema.prepare(it)
		opened += it
	}

	private val store by lazy { NoteStore(connection()) }

	@After
	fun close() = opened.forEach { it.close() }

	private fun note(body: String, at: Long = 1_786_011_720_123, ext: ByteArray = ByteArray(0)) =
		Note(UUID.randomUUID(), body, at, at, dirty = true, ext = ext)

	private fun pulled(note: Note, v: Long) = store.put(Note(note.id, note.body, note.createdAt, note.updatedAt, v = v, ext = note.ext), pulled = true)

	@Test
	fun roundTripsANoteWithExactMillisecondsAndExt() {
		val original = note("title\nbody", at = Long.MIN_VALUE + 1, ext = byteArrayOf(0, 1, 2))

		store.save(original)

		assertEquals(original, store.note(original.id))
		assertArrayEquals(byteArrayOf(0, 1, 2), store.note(original.id)!!.ext)
	}

	@Test
	fun updatesInPlaceAndKeepsCreatedAt() {
		val original = note("first")
		store.save(original)

		store.save(original.copy(body = "second", updatedAt = original.updatedAt + 5))

		val saved = store.note(original.id)!!
		assertEquals("second", saved.body)
		assertEquals(original.createdAt, saved.createdAt)
		assertEquals(original.updatedAt + 5, saved.updatedAt)
		assertEquals("1", connection().scalar("SELECT count(*) FROM note"))
	}

	@Test
	fun keepsBodiesWithEmbeddedNulAndEveryPlaneIntact() {
		val body = "before\u0000after 😀 \uD800 \u200D"
		val saved = note(body)
		store.save(saved)

		assertEquals(body.encodeToByteArray().decodeToString(), store.note(saved.id)!!.body)
		assertEquals("before\u0000after 😀 ? \u200D", store.note(saved.id)!!.body)
	}

	@Test
	fun deletionKeepsATombstoneStampedWithTheMoment() {
		val original = note("doomed", ext = byteArrayOf(9))
		store.save(original)

		store.markDeleted(original.id, 42)

		val tombstone = store.note(original.id)!!
		assertTrue(tombstone.deleted)
		assertTrue(tombstone.dirty)
		assertEquals("", tombstone.body)
		assertEquals(0, tombstone.ext.size)
		assertEquals(42L, tombstone.updatedAt)
		assertEquals(emptyList<Note>(), store.liveNotes())
	}

	@Test
	fun aSaveNeverRevivesATombstone() {
		val original = note("doomed")
		store.save(original)
		store.markDeleted(original.id, 42)

		assertEquals(NoteStore.Saved.InPlace, store.save(original.copy(body = "typed late")))

		assertTrue(store.note(original.id)!!.deleted)
		assertEquals("", store.note(original.id)!!.body)
	}

	@Test
	fun listsNewestFirstAndReportsPendingPushes() {
		val older = note("older", at = 1_000)
		val newer = note("newer", at = 2_000)
		val synced = Note(UUID.randomUUID(), "synced", 1_500, 1_500, v = 3)
		listOf(older, synced, newer).forEach { store.save(it) }

		assertEquals(listOf("newer", "synced", "older"), store.liveNotes().map { it.body })
		assertEquals(setOf("older", "newer"), store.pendingPushes().map { it.body }.toSet())
	}

	@Test
	fun aMissingNoteReadsAsNilAndAMalformedIdIsSkipped() {
		assertNull(store.note(UUID.randomUUID()))
		connection().execute("INSERT INTO note (uuid, body, createdAt, updatedAt) VALUES (x'0102', 'short id', 0, 0)")

		assertEquals(emptyList<Note>(), store.liveNotes())
	}

	@Test
	fun insertsOnlyTheNotesItDoesNotHoldAndReturnsThem() {
		val held = note("held")
		store.save(held)
		val fresh = note("fresh")

		val added = store.insertMissing(listOf(held.copy(body = "imported copy"), fresh))

		assertEquals(listOf(fresh), added)
		assertEquals("held", store.note(held.id)!!.body)
		assertEquals("fresh", store.note(fresh.id)!!.body)
	}

	@Test
	fun anInsertThatFailsPartWayAddsNothing() {
		connection().execute("CREATE TRIGGER refuse BEFORE INSERT ON note WHEN new.body = 'refused' BEGIN SELECT RAISE(ABORT, 'refused'); END")

		val failure = runCatching { store.insertMissing(listOf(note("accepted"), note("refused"))) }.exceptionOrNull()

		assertTrue(failure is SQLiteException)
		assertEquals(emptyList<Note>(), store.liveNotes())
	}

	@Test
	fun discardingANeverPushedNoteRemovesItsRow() {
		val empty = note("")
		store.save(empty)

		store.discardUnsynced(empty.id, shownAt = 0, moment = 50)

		assertNull(store.note(empty.id))
	}

	@Test
	fun discardingAPushedNoteLeavesATombstone() {
		val pushed = note("")
		pulled(pushed, v = 1)
		connection().execute("UPDATE note SET pulled = 0")

		store.discardUnsynced(pushed.id, shownAt = 1, moment = 50)

		assertTrue(store.note(pushed.id)!!.deleted)
	}

	@Test
	fun discardingANoteAPullWroteSinceItWasShownKeepsThePulledText() {
		val shown = note("")
		pulled(shown.copy(body = "from another device"), v = 2)

		store.discardUnsynced(shown.id, shownAt = 0, moment = 50)

		val kept = store.note(shown.id)!!
		assertFalse(kept.deleted)
		assertEquals("from another device", kept.body)
	}

	@Test
	fun anEditBegunBeforeAPullLandsAsACopyAndLeavesThePulledText() {
		val original = note("mine")
		store.save(original)
		pulled(original.copy(body = "theirs"), v = 4)

		val saved = store.save(original.copy(body = "mine, edited", updatedAt = original.updatedAt + 1))

		assertTrue(saved is NoteStore.Saved.Copied)
		val copy = store.note((saved as NoteStore.Saved.Copied).id)!!
		assertEquals("mine, edited", copy.body)
		assertTrue(copy.dirty)
		assertEquals(0L, copy.v)
		assertEquals("theirs", store.note(original.id)!!.body)
	}

	@Test
	fun findsNotesByBody() {
		store.save(note("shopping list\nquartz and bread"))
		store.save(note("meeting notes\nbudget review"))

		assertEquals(listOf("shopping list"), store.search("quartz").map { it.title })
		assertEquals(listOf("meeting notes"), store.search("budget").map { it.title })
		assertEquals(emptyList<Note>(), store.search("absent"))
	}

	@Test
	fun treatsPunctuationAsPlainTextRatherThanQuerySyntax() {
		store.save(note("reply to e-mail\ndon't forget the c++ notes"))

		for (term in listOf("don't", "e-mail", "c++", "\"", "-", "(", "*", "a,b", "AND", "OR", "NOT", "", "   ", "\u0D4E\"", "kayak \u0D4E\"", "\u0D4E\"\u0301", "\u0D4E\"\uFE0F", "kayak \u0D4E\"\u0301", "NEAR(a b)", "body:x", "^x")) {
			store.search(term)
		}

		assertEquals(1, store.search("e-mail").size)
		assertEquals(1, store.search("don't").size)
		assertEquals(emptyList<Note>(), store.search(""))
		assertEquals(emptyList<Note>(), store.search("   "))
	}

	@Test
	fun followsEditsAndDeletions() {
		val kayak = note("kayak")
		store.save(kayak)
		assertEquals(1, store.search("kayak").size)

		store.save(kayak.copy(body = "canoe"))
		assertEquals(0, store.search("kayak").size)
		assertEquals(1, store.search("canoe").size)

		store.markDeleted(kayak.id, 1)
		assertEquals(0, store.search("canoe").size)
	}

	@Test
	fun matchesAPrefixOfTheLastWordFromTwoCharacters() {
		store.save(note("kayak trip"))

		assertEquals(1, store.search("kay").size)
		assertEquals(1, store.search("kayak tr").size)
		assertEquals(0, store.search("kay trip").size)
		assertEquals(0, store.search("k").size)
		assertEquals(0, store.search("kayak t").size)
	}

	@Test
	fun ranksByRelevanceNotDate() {
		store.save(note("newer\nmentions kayak once", at = 2_000))
		store.save(note("older\nkayak kayak kayak kayak", at = 1_000))

		assertEquals(listOf("older", "newer"), store.search("kayak").map { it.title })
	}

	@Test
	fun theMatchExpressionQuotesEveryWord() {
		assertEquals("\"don\" \"t\"", NoteStore.matchExpression("don't"))
		assertNull(NoteStore.matchExpression(" -- "))
		assertEquals("\"kayak\" \"trip\"*", NoteStore.matchExpression("kayak, trip"))
		assertEquals("\"kayak\" \"t\"", NoteStore.matchExpression("kayak t"))
	}

	@Test
	fun storesTheIdAsItsSixteenBytes() {
		val original = note("stored")
		store.save(original)

		val stored = connection().prepare("SELECT uuid FROM note").use {
			it.step()
			it.bytes(0)
		}
		assertArrayEquals(original.id.bytes(), stored)
	}
}
