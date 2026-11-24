package dev.hloth.nativenote.model

import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.Argon2Calibration
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.support.appModel
import dev.hloth.nativenote.support.await
import dev.hloth.nativenote.support.cheapArgon
import dev.hloth.nativenote.support.onMain
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockRecordFile
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppModelTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val password = "correct horse battery staple"
	private val files get() = LibraryFiles(folder.root)

	private fun setUpLibrary(model: AppModel = appModel(folder.root)): AppModel {
		model.await { start() }
		model.await { setUp(password) }
		return model
	}

	private fun locked(model: AppModel = setUpLibrary()): AppModel = model.also { it.await { lock() } }

	private fun libraryFiles() = folder.root.list()!!.sorted()

	@Test
	fun aFirstRunSetsUpAndOpensTheLibraryInOnboarding() {
		val model = appModel(folder.root)
		model.await { start() }
		assertEquals(AppModel.Phase.NeedsSetup, model.phase)

		model.await { setUp(password) }

		assertEquals(AppModel.Phase.Unlocked, model.phase)
		assertTrue(model.isOnboarding)
		assertNull(model.failure)
		assertTrue(files.record.read() != null)
		assertTrue(files.holdsDatabase)
	}

	@Test
	fun lockingClosesTheDatabaseLeavingOnlyTheLibraryAndItsRecord() {
		val model = locked()

		assertEquals(AppModel.Phase.Locked, model.phase)
		assertFalse(model.isOnboarding)
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), libraryFiles())
	}

	@Test
	fun aRelaunchFindsTheLibraryLockedAndOnlyThePasswordOpensIt() {
		locked()
		val relaunched = appModel(folder.root)
		relaunched.await { start() }
		assertEquals(AppModel.Phase.Locked, relaunched.phase)

		relaunched.await { unlock("correct horse battery stapler") }
		assertEquals(Failure.WrongPassword, relaunched.failure)
		assertEquals(AppModel.Phase.Locked, relaunched.phase)

		relaunched.await { unlock(password) }
		assertEquals(AppModel.Phase.Unlocked, relaunched.phase)
		assertFalse(relaunched.isOnboarding)
		assertNull(relaunched.failure)
	}

	@Test
	fun anUnlockThatFinishesAfterTheAppStoppedLocksAgain() {
		val model = locked()

		val unlocking = onMain { model.unlock(password) }
		onMain { model.appStopped() }
		runBlocking { unlocking.join() }

		assertEquals(AppModel.Phase.Locked, model.phase)
		model.await { lock() }
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), libraryFiles())
	}

	@Test
	fun leavingTheAppLocksAnUnlockedLibrary() {
		val model = setUpLibrary()

		onMain { model.appStopped() }
		model.await { lock() }

		assertEquals(AppModel.Phase.Locked, model.phase)
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), libraryFiles())
	}

	@Test
	fun setupSetsAsideADatabaseLeftWithoutARecordAndNeverDeletesIt() {
		folder.root.resolve("notes.db").writeText("an older library")
		folder.root.resolve("notes.db-wal").writeText("its log")

		setUpLibrary()

		val asides = libraryFiles().filter { it.startsWith(LibraryFiles.SET_ASIDE_PREFIX) }
		assertEquals(2, asides.size)
		assertEquals("an older library", folder.root.resolve(asides.single { it.endsWith(".db") }).readText())
	}

	@Test
	fun erasingRemovesTheLibraryItsRecordAndMachineKeysThenReturnsToSetup() {
		val model = locked(setUpLibrary(appModel(folder.root, makeParameters = {
			UnlockKeys.makeParameters(strongBox = false) { cheapArgon }
		})))
		folder.root.resolve("${LibraryFiles.SET_ASIDE_PREFIX}20260101T000000Z-1.db").writeText("set aside")

		model.await { erase() }

		assertEquals(AppModel.Phase.NeedsSetup, model.phase)
		assertNull(model.failure)
		assertEquals(emptyList<String>(), libraryFiles())
		val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
		assertTrue(keyStore.aliases().toList().none { it.startsWith("native-note.machine.") })
	}

	@Test
	fun anUnreadableRecordIsReportedNeverTakenForAFirstRun() {
		locked()
		files.record.file.writeBytes(byteArrayOf(1, 2, 3))
		val relaunched = appModel(folder.root)

		relaunched.await { start() }
		relaunched.await { unlock(password) }

		assertEquals(AppModel.Phase.Locked, relaunched.phase)
		assertEquals(Failure.Unexpected(R.string.failure_record_damaged), relaunched.failure)
	}

	@Test
	fun aLibraryFromANewerVersionIsRefused() {
		val model = setUpLibrary()
		val key = UnlockKeys.databaseKey(password, files.record.read()!!)
		model.await { lock() }
		SQLiteConnection(files.database, key, create = false).use { it.execute("PRAGMA user_version = 2") }

		model.await { unlock(password) }

		assertEquals(AppModel.Phase.Locked, model.phase)
		assertEquals(Failure.Unexpected(R.string.failure_schema_newer), model.failure)
	}

	@Test
	fun changingThePasswordReplacesTheRecordAndKeepsItsMemoryAndMachineKey() {
		val stronger = cheapArgon.copy(m = 16 * 1024)
		val model = setUpLibrary(appModel(folder.root, calibrate = { stronger }))
		val before = files.record.read()!!

		val failure = runBlocking { onMain { model.changePassword(password, "a new password") }.await() }

		assertNull(failure)
		val after = files.record.read()!!
		assertFalse(before.parameters.localSalt.contentEquals(after.parameters.localSalt))
		assertEquals(stronger, after.parameters.argon)
		assertEquals(before.parameters.machineKeyId?.toList(), after.parameters.machineKeyId?.toList())
		model.await { lock() }
		model.await { unlock(password) }
		assertEquals(Failure.WrongPassword, model.failure)
		model.await { unlock("a new password") }
		assertEquals(AppModel.Phase.Unlocked, model.phase)
	}

	@Test
	fun aPasswordChangeNeverLowersTheMemoryCost() {
		val model = setUpLibrary(appModel(folder.root, calibrate = { cheapArgon.copy(m = 4 * 1024) }))

		runBlocking { onMain { model.changePassword(password, "another") }.await() }

		assertEquals(cheapArgon, files.record.read()!!.parameters.argon)
	}

	@Test
	fun aWrongCurrentPasswordChangesNothing() {
		val model = setUpLibrary()
		val before = files.record.file.readBytes()

		val failure = runBlocking { onMain { model.changePassword("not it", "a new password") }.await() }

		assertEquals(Failure.WrongPassword, failure)
		assertTrue(before.contentEquals(files.record.file.readBytes()))
	}

	@Test
	fun lockingDuringAPasswordChangeCancelsItBeforeTheRecordIsReplaced() {
		val calibrating = CountDownLatch(1)
		val resume = CountDownLatch(1)
		val model = setUpLibrary(appModel(folder.root, calibrate = {
			calibrating.countDown()
			resume.await(10, TimeUnit.SECONDS)
			cheapArgon
		}))
		val before = files.record.file.readBytes()

		val change = onMain { model.changePassword(password, "a new password") }
		calibrating.await(10, TimeUnit.SECONDS)
		val locking = onMain { model.lock() }
		resume.countDown()
		runBlocking { locking.join() }

		assertTrue(change.isCancelled)
		assertTrue(before.contentEquals(files.record.file.readBytes()))
		assertEquals(listOf("notes.db", UnlockRecordFile.NAME), libraryFiles())
	}

	@Test
	fun aCalibratedHardwareBoundLibrarySurvivesARelaunch() {
		val strongBox = InstrumentationRegistry.getInstrumentation().targetContext.packageManager
			.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
		val calibrated: () -> Argon2.Parameters = { Argon2Calibration.calibrateMemory() }
		locked(setUpLibrary(appModel(folder.root, makeParameters = { UnlockKeys.makeParameters(strongBox, calibrated) }, calibrate = calibrated)))
		val relaunched = appModel(folder.root)

		relaunched.await { start() }
		relaunched.await { unlock(password) }

		assertEquals(AppModel.Phase.Unlocked, relaunched.phase)
		assertNotEquals(cheapArgon, files.record.read()!!.parameters.argon)
		relaunched.await { lock() }
		runCatching { relaunched.await { erase() } }
	}

	@Test
	fun aPasswordChangeCanceledBeforeItStartsDoesNotBlockTheNext() {
		val model = setUpLibrary()
		val changed = runBlocking {
			withContext(Dispatchers.Main) {
				val change = model.changePassword(password, "never applied")
				model.lock()
				change
			}
		}
		runBlocking { changed.join() }
		model.await { unlock(password) }

		assertNull(runBlocking { onMain { model.changePassword(password, "a new password") }.await() })
	}

	@Test
	fun anUnlockIsRefusedWhileErasing() {
		val model = locked()

		val jobs = onMain { listOf(model.erase(), model.unlock(password)) }
		runBlocking { jobs.forEach { it.join() } }

		assertEquals(AppModel.Phase.NeedsSetup, onMain { model.phase })
		assertNull(onMain { model.failure })
	}
}
