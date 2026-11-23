package dev.hloth.nativenote.unlock

import android.content.pm.PackageManager
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.Argon2Calibration
import dev.hloth.nativenote.crypto.MachineKey
import dev.hloth.nativenote.storage.SQLiteConnection
import java.io.File
import java.security.KeyStore
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UnlockKeysTest {
	@get:Rule
	val folder = TemporaryFolder()

	private val strongBox = InstrumentationRegistry.getInstrumentation().targetContext.packageManager
		.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
	private val cheap = Argon2.Parameters(m = 8 * 1024, t = 1, p = 4)
	private val madeParameters = mutableListOf<UnlockParameters>()

	private fun parameters(calibrate: () -> Argon2.Parameters = { cheap }) =
		UnlockKeys.makeParameters(strongBox, calibrate).also { madeParameters += it }

	@After
	fun deleteMachineKeys() = madeParameters.mapNotNull { it.machineKeyId }.forEach { runCatching { MachineKey.load(it).delete() } }

	@Test
	fun aCalibratedRecordOnDiskOpensTheLibraryAfterARestart() {
		val calibrationStarted = SystemClock.elapsedRealtime()
		val parameters = parameters { Argon2Calibration.calibrateMemory() }
		Log.i("UnlockKeysTest", "calibrated m=${parameters.argon.m} KiB in ${SystemClock.elapsedRealtime() - calibrationStarted} ms, machine key ${parameters.machineKeyId != null}")
		val localDbKey = AesGcm.randomBytes(32)
		val database = File(folder.root, "notes.db")
		SQLiteConnection(database, localDbKey).use { it.execute("CREATE TABLE note (body TEXT NOT NULL); INSERT INTO note VALUES ('kept')") }
		UnlockRecordFile.inDirectory(folder.root).write(UnlockKeys.makeRecord("correct horse battery staple", localDbKey, parameters))

		val unlockStarted = SystemClock.elapsedRealtime()
		val record = UnlockRecordFile.inDirectory(folder.root).read()!!
		val reopenedKey = UnlockKeys.databaseKey("correct horse battery staple", record)
		Log.i("UnlockKeysTest", "unlock took ${SystemClock.elapsedRealtime() - unlockStarted} ms")

		assertTrue(parameters.argon.m >= Argon2.Parameters.floor.m)
		assertEquals(0, parameters.argon.m % (8 * parameters.argon.p))
		assertArrayEquals(localDbKey, reopenedKey)
		assertEquals("kept", SQLiteConnection(database, reopenedKey).use { it.scalar("SELECT body FROM note") })
	}

	@Test
	fun aWrongPasswordIsRefusedByTheWrap() {
		val record = UnlockKeys.makeRecord("correct horse battery staple", AesGcm.randomBytes(32), parameters())

		assertThrows(UnlockKeys.WrongPassword::class.java) { UnlockKeys.databaseKey("correct horse battery stapler", record) }
	}

	@Test
	fun theMachineKeyBindsTheRecordToThisDevice() {
		val machineKey = MachineKey.create(strongBox)
		val parameters = UnlockParameters(AesGcm.randomBytes(16), cheap, machineKey.id).also { madeParameters += it }
		val password = "correct horse battery staple"
		val record = UnlockKeys.makeRecord(password, AesGcm.randomBytes(32), parameters)

		val elsewhere = UnlockRecord(UnlockParameters(parameters.localSalt, parameters.argon, null), record.wrappedKey)
		assertThrows(UnlockKeys.WrongPassword::class.java) { UnlockKeys.databaseKey(password, elsewhere) }
		machineKey.delete()
		assertThrows(MachineKey.BoundToAnotherDevice::class.java) { UnlockKeys.databaseKey(password, record) }
	}

	@Test
	fun onlyAHardwareBackedMachineKeyIsKept() {
		val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
		val before = keyStore.aliases().toList().toSet()

		val parameters = parameters()
		val added = keyStore.aliases().toList().toSet() - before

		if (parameters.machineKeyId == null) {
			assertEquals(emptySet<String>(), added)
		} else {
			assertTrue(MachineKey.load(parameters.machineKeyId).isHardwareBacked)
			assertEquals(1, added.size)
		}
	}

	@Test
	fun aRecordWithoutAMachineKeyOpensWithThePasswordAlone() {
		val unbound = UnlockParameters(AesGcm.randomBytes(16), cheap, null)
		val localDbKey = AesGcm.randomBytes(32)

		val record = UnlockKeys.makeRecord("pin 1234", localDbKey, unbound)

		assertArrayEquals(localDbKey, UnlockKeys.databaseKey("pin 1234", UnlockRecord.decode(record.encoded())))
	}

	@Test
	fun eachSetupDrawsAFreshSaltAndMachineKey() {
		val first = parameters()
		val second = parameters()

		assertFalse(first.localSalt.contentEquals(second.localSalt))
		if (first.machineKeyId != null) assertNotNull(second.machineKeyId)
		first.machineKeyId?.let { assertFalse(it.contentEquals(second.machineKeyId)) }
	}
}
