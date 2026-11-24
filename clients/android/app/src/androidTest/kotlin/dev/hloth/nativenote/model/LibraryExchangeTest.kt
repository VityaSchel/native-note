package dev.hloth.nativenote.model

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.export.ExportEnvelope
import dev.hloth.nativenote.export.LibraryArchive
import dev.hloth.nativenote.support.FakeBiometricVault
import dev.hloth.nativenote.support.RealisticCorpus
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.cheapArgon
import dev.hloth.nativenote.support.onMain
import java.io.File
import java.io.IOException
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
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
class LibraryExchangeTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"

	private fun library(
		name: String,
		bodies: List<String> = emptyList(),
		exportParameters: Argon2.Parameters = cheapArgon,
		memoryAvailable: () -> Long = { Long.MAX_VALUE },
		biometricVault: FakeBiometricVault? = null,
	): AppModel {
		val model = appModel(
			File(folder.root, name).apply { mkdirs() },
			exportParameters = exportParameters,
			memoryAvailable = memoryAvailable,
			biometricVault = biometricVault ?: FakeBiometricVault(),
			biometricsAvailable = { biometricVault != null },
		)
		model.await { start() }
		model.await { setUp(password) }
		onMain { model.finishOnboarding() }
		for (body in bodies) {
			model.await { createNote() }
			onMain { model.edit(model.selection!!, body) }
		}
		onMain { model.select(null) }
		runBlocking { withContext(Dispatchers.Main) { model.flushPendingSaves() } }
		return model
	}

	private fun AppModel.exported(passphrase: String? = null): ByteArray? {
		var file: ByteArray? = null
		onMain { prepareExport(passphrase) }
		val written = runBlocking { withContext(Dispatchers.Main) { exportLibrary { file = it }.await() } }
		return if (written) file else null
	}

	private fun AppModel.imported(file: ByteArray, passphrase: String? = null, size: Long = file.size.toLong()): ImportSummary? {
		onMain { prepareImport() }
		return runBlocking { withContext(Dispatchers.Main) { importLibrary(passphrase, { size }) { file }.await() } }
	}

	private fun AppModel.failureReason() = (onMain { failure } as? Failure.Unexpected)?.reason

	private fun AppModel.shown() = onMain { notes }.sortedBy { it.id }

	private val corpus = RealisticCorpus.bodies(40) + listOf("CR\r\nkept\r", "emoji \uD83D\uDE00", "Same title", "Same title", "a/b:c")

	@Test
	fun anExportRestoresEveryNoteIntoAnEmptyLibrary() {
		val source = library("source", corpus)
		val target = library("target")

		val summary = target.imported(source.exported()!!)

		val expected = source.shown()
		assertEquals(ImportSummary(added = expected.size), summary)
		assertTrue(expected.size > 40)
		val restored = target.shown()
		assertEquals(expected.map { listOf(it.id, it.body, it.createdAt, it.updatedAt) }, restored.map { listOf(it.id, it.body, it.createdAt, it.updatedAt) })
		assertTrue(restored.all { it.dirty && it.v == 0L && !it.deleted && it.ext.isEmpty() })
	}

	@Test
	fun anEncryptedExportOpensOnlyWithItsPassphrase() {
		val source = library("source", listOf("Secret\ntext"))
		val target = library("target")
		val file = source.exported("export passphrase")!!

		assertTrue(onMain { target.isEncryptedExport(file.copyOf(64)) })
		assertFalse(String(file, Charsets.ISO_8859_1).contains("Secret"))
		assertNull(target.imported(file, "wrong passphrase"))
		assertEquals(Failure.WrongExportPassphrase, onMain { target.failure })
		assertNull(target.imported(file))
		assertEquals(R.string.failure_not_an_export, target.failureReason())

		assertEquals(ImportSummary(added = 1), target.imported(file, "export passphrase"))
	}

	@Test
	fun aPlainExportIsNotReportedAsEncrypted() {
		val file = library("source", listOf("Plain")).exported()!!

		assertFalse(ExportEnvelope.isEncrypted(file))
		assertEquals("PK", String(file.copyOf(2), Charsets.US_ASCII))
	}

	@Test
	fun anImportAddsOnlyNotesTheLibraryHasNeverHeldAndKeepsChangesMadeSince() {
		val model = library("library", listOf("Kept\nas exported", "Edited\nbefore", "Deleted\nhere"))
		val file = model.exported()!!
		val notes = model.shown()
		val edited = notes.single { it.title == "Edited" }
		onMain { model.edit(edited.id, "Edited\nafter the export") }
		runBlocking { onMain { model.delete(notes.single { it.title == "Deleted" }.id) }.await() }

		val summary = model.imported(file)

		assertEquals(ImportSummary(added = 0, skipped = 3), summary)
		assertEquals(setOf("Kept", "Edited"), model.shown().map { it.title }.toSet())
		assertEquals("Edited\nafter the export", model.shown().single { it.id == edited.id }.body)
	}

	@Test
	fun anImportedNoteAlreadyShownIsListedOnceAndTwoImportsAtOnceAddEachNoteOnce() {
		val file = library("source", listOf("One", "Two")).exported()!!
		val target = library("target")
		val reading = CountDownLatch(1)
		val release = CountDownLatch(1)

		onMain { target.prepareImport() }
		val first = onMain {
			target.importLibrary(null, { file.size.toLong() }) {
				reading.countDown()
				release.await(10, TimeUnit.SECONDS)
				file
			}
		}
		assertTrue(reading.await(10, TimeUnit.SECONDS))
		val second = onMain { target.importLibrary(null, { file.size.toLong() }) { file } }
		release.countDown()

		assertNull(runBlocking { second.await() })
		assertEquals(ImportSummary(added = 2), runBlocking { first.await() })
		assertEquals(ImportSummary(skipped = 2), target.imported(file))
		assertEquals(2, target.shown().size)
	}

	@Test
	fun lockingDuringAnImportReportsWhatWasLeft() {
		val file = library("source", listOf("One", "Two", "Three")).exported()!!
		val target = library("target")
		val reading = CountDownLatch(1)
		val release = CountDownLatch(1)

		onMain { target.prepareImport() }
		val importing = onMain {
			target.importLibrary(null, { file.size.toLong() }) {
				reading.countDown()
				release.await(10, TimeUnit.SECONDS)
				file
			}
		}
		assertTrue(reading.await(10, TimeUnit.SECONDS))
		onMain { target.lock() }
		release.countDown()

		assertEquals(ImportSummary(notImported = 3), runBlocking { importing.await() })
	}

	@Test
	fun aLockedLibraryExportsNothing() {
		val model = library("library", listOf("Secret"))
		onMain { model.prepareExport(null) }
		model.await { lock() }
		var written = false

		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { written = true }.await() } })
		assertFalse(written)
	}

	@Test
	fun aLockWhileTheSavePickerIsOpenCancelsTheExportEvenAfterUnlocking() {
		val model = library("library", listOf("Secret"))
		onMain { model.prepareExport("chosen passphrase") }
		onMain { model.appStopped() }
		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
		onMain { model.screenTurnedOff() }
		model.await { lock() }
		model.await { unlock(password) }
		var written: ByteArray? = null

		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { written = it }.await() } })
		assertNull(written)
	}

	@Test
	fun anExportTheLockRefusedSaysSoAndACanceledPickerSaysNothing() {
		val model = library("library", listOf("Note"))
		onMain { model.prepareExport(null) }
		model.await { lock() }
		model.await { unlock(password) }

		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { }.await() } })
		assertEquals(R.string.failure_export_locked, model.failureReason())

		onMain { model.dismissFailure() }
		onMain { model.prepareExport(null) }
		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary(null).await() } })
		assertNull(onMain { model.failure })
	}

	@Test
	fun aTouchThatUnlocksKeepsTheMessageThatNothingWasExported() {
		val vault = FakeBiometricVault()
		val model = library("library", listOf("Note"), biometricVault = vault)
		model.await { appStarted() }
		assertNull(runBlocking {
			onMain {
				model.enableBiometricUnlock(password) {
					vault.touched = true
					AppModel.BiometricOutcome.Succeeded
				}
			}.await()
		})
		onMain {
			model.prepareExport(null)
			model.screenTurnedOff()
		}
		model.await { lock() }

		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { }.await() } })
		model.await { appStarted() }
		onMain { model.biometricPromptShown() }
		vault.touched = true
		model.await { biometricPromptEnded(AppModel.BiometricOutcome.Succeeded) }

		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })
		assertEquals(R.string.failure_export_locked, model.failureReason())
	}

	@Test
	fun aFilePickedAfterTheLockSaysItWasNotImported() {
		val file = library("source", listOf("Note")).exported()!!
		val model = library("target")
		onMain { model.prepareImport() }
		model.await { lock() }

		assertNull(runBlocking { withContext(Dispatchers.Main) { model.importLibrary(null, { file.size.toLong() }) { file }.await() } })

		assertEquals(R.string.failure_import_locked, model.failureReason())
	}

	@Test
	fun anExportAndAnImportReportWhatTheyDid() {
		val source = library("source", listOf("One", "Two"))
		val target = library("target")

		val file = source.exported()!!
		assertEquals(AppModel.Exchanged.Exported(2), onMain { source.exchanged })
		onMain { source.dismissExchanged() }
		assertNull(onMain { source.exchanged })

		target.imported(file)
		assertEquals(AppModel.Exchanged.Imported(ImportSummary(added = 2)), onMain { target.exchanged })
	}

	@Test
	fun runningOutOfMemorySaysSo() {
		val model = library("library", listOf("Note"))

		onMain { model.prepareExport(null) }
		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { throw OutOfMemoryError() }.await() } })
		assertEquals(R.string.failure_too_large_for_device, model.failureReason())
	}

	@Test
	fun aSlowDocumentProviderDoesNotHoldUpSaves() {
		val model = library("library", listOf("Note"))
		val released = CountDownLatch(1)
		val reading = onMain {
			model.importLibrary(null, { 1 }) {
				released.await()
				ByteArray(0)
			}
		}

		onMain { model.edit(model.notes.single().id, "edited while the file is read") }
		runBlocking { withTimeout(5_000) { withContext(Dispatchers.Main) { model.flushPendingSaves() } } }

		released.countDown()
		runBlocking { reading.await() }
	}

	@Test
	fun anImportRerunsAnActiveSearch() {
		val file = library("source", listOf("Kayak rental")).exported()!!
		val target = library("target", listOf("Groceries"))
		onMain { target.updateSearch("kayak") }

		target.imported(file)

		val grouping = NoteGrouping(0, ZoneId.of("UTC"), NoteGrouping.Words("", "", "", { day, time -> "$day $time" }, DateTimeFormatter.ISO_TIME, Locale.US))
		assertEquals(listOf("Kayak rental"), onMain { target.groups(grouping, "Results") }.flatMap { it.notes }.map { it.title })
	}

	@Test
	fun leavingForThePickerKeepsTheLibraryUnlockedUntilItCloses() {
		val model = library("library")

		onMain { model.prepareImport() }
		onMain { model.appStopped() }
		assertEquals(AppModel.Phase.Unlocked, onMain { model.phase })

		onMain { model.pickerClosed() }
		onMain { model.appStopped() }
		assertEquals(AppModel.Phase.Locked, onMain { model.phase })
	}

	@Test
	fun anEncryptedExportCarriesTheModelsParametersAndTheDefaultIsTheFloor() {
		val cheap = library("cheap", listOf("x")).exported("p")!!
		val floor = library("floor", listOf("x"), exportParameters = Argon2.Parameters.floor).exported("p")!!

		assertArrayEquals(ExportEnvelope.header(cheapArgon, cheap.copyOfRange(21, 37)), cheap.copyOf(37))
		assertArrayEquals(ExportEnvelope.header(Argon2.Parameters.floor, floor.copyOfRange(21, 37)), floor.copyOf(37))
	}

	@Test
	fun theExportCarriesEditsNotYetSaved() {
		val model = library("library", listOf("Draft"))
		val id = model.shown().single().id
		onMain { model.edit(id, "Draft\ntyped a moment ago") }

		val notes = LibraryArchive.notes(model.exported()!!)

		assertEquals("Draft\ntyped a moment ago", notes.single().body)
	}

	@Test
	fun aFileTooLargeToBeAnExportIsRefusedUnread() {
		val model = library("library")
		var read = false
		onMain { model.prepareImport() }

		val summary = runBlocking {
			withContext(Dispatchers.Main) {
				model.importLibrary(null, { LibraryArchive.MAXIMUM_SIZE + 1 }) {
					read = true
					ByteArray(0)
				}.await()
			}
		}

		assertNull(summary)
		assertFalse(read)
		assertEquals(R.string.failure_import_too_large, model.failureReason())
	}

	@Test
	fun aFileTooLargeForThisDeviceIsRefusedUnread() {
		val model = library("library", memoryAvailable = { 1_000 })
		var read = false
		onMain { model.prepareImport() }

		runBlocking {
			withContext(Dispatchers.Main) {
				model.importLibrary(null, { 300 }) {
					read = true
					ByteArray(0)
				}.await()
			}
		}

		assertFalse(read)
		assertEquals(R.string.failure_too_large_for_device, model.failureReason())
	}

	@Test
	fun aFileThatIsNotAnExportOrIsFromANewerVersionSaysSo() {
		val model = library("library")

		assertNull(model.imported("just some text".encodeToByteArray()))
		assertEquals(R.string.failure_not_an_export, model.failureReason())
		assertEquals(R.string.failure_import, (onMain { model.failure } as Failure.Unexpected).title)

		assertNull(model.imported("NNEXPORT2 and more".encodeToByteArray()))
		assertEquals(R.string.failure_export_newer, model.failureReason())
	}

	@Test
	fun aFileThatCannotBeWrittenOrReadSaysSo() {
		val model = library("library", listOf("x"))
		onMain { model.prepareExport(null) }

		assertFalse(runBlocking { withContext(Dispatchers.Main) { model.exportLibrary { throw IOException("disk full") }.await() } })
		assertEquals(R.string.failure_file, model.failureReason())
		assertEquals(R.string.failure_export, (onMain { model.failure } as Failure.Unexpected).title)

		onMain { model.prepareImport() }
		assertNull(runBlocking { withContext(Dispatchers.Main) { model.importLibrary(null, { throw IOException("gone") }) { ByteArray(0) }.await() } })
		assertEquals(R.string.failure_file, model.failureReason())
	}

	@Test
	fun importedNotesLandOnDiskDirtyAtVersionZero() {
		val file = library("source", listOf("Synced elsewhere")).exported()!!
		val target = library("target")
		target.imported(file)
		target.await { lock() }
		target.await { unlock(password) }

		val note = target.shown().single()
		assertTrue(note.dirty)
		assertEquals(0L, note.v)
	}
}
