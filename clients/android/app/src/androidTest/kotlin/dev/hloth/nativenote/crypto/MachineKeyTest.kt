package dev.hloth.nativenote.crypto

import android.content.pm.PackageManager
import android.security.keystore.KeyProperties
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MachineKeyTest {
	private val strongBox = InstrumentationRegistry.getInstrumentation().targetContext.packageManager
		.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)
	private val created = mutableListOf<MachineKey>()

	private fun create() = MachineKey.create(strongBox).also { created += it }

	@After
	fun deleteKeys() = created.forEach { it.delete() }

	@Test
	fun theMachineIdIsDeterministicPerKeyAndSurvivesALoadFromTheKeystore() {
		val key = create()
		val machineId = key.machineId()

		assertEquals(32, machineId.size)
		assertArrayEquals(machineId, key.machineId())
		assertArrayEquals(machineId, MachineKey.load(key.id).machineId())
		assertFalse(machineId.contentEquals(create().machineId()))
	}

	@Test
	fun theKeyNeverPromptsNorLeavesTheKeystore() {
		val key = create()
		val info = key.keyInfo
		Log.i("MachineKeyTest", "security level ${info.securityLevel}, StrongBox feature $strongBox")

		assertFalse(info.isUserAuthenticationRequired)
		assertEquals(KeyProperties.PURPOSE_SIGN, info.purposes)
		assertEquals(info.securityLevel != KeyProperties.SECURITY_LEVEL_SOFTWARE, key.isHardwareBacked)
		if (strongBox) assertEquals(KeyProperties.SECURITY_LEVEL_STRONGBOX, info.securityLevel)
	}

	@Test
	fun aDeletedOrForeignKeyReadsAsBoundToAnotherDevice() {
		val key = create()
		key.delete()

		assertThrows(MachineKey.BoundToAnotherDevice::class.java) { MachineKey.load(key.id) }
		assertThrows(MachineKey.BoundToAnotherDevice::class.java) { MachineKey.load(AesGcm.randomBytes(MachineKey.ID_LENGTH)) }
	}
}
