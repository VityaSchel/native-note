package dev.hloth.nativenote.crypto

import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Argon2Test {
	private val salt = ByteArray(16) { it.toByte() }
	private val cheap = Argon2.Parameters(m = 1024, t = 1, p = 1)

	@Test
	fun theProductionFloorRunsInProcessAndRepeats() {
		val started = SystemClock.elapsedRealtime()
		val first = Argon2.hash("correct horse battery staple", salt, Argon2.Parameters.floor)
		Log.i("Argon2Test", "floor m=${Argon2.Parameters.floor.m} KiB t=${Argon2.Parameters.floor.t} p=${Argon2.Parameters.floor.p}: ${SystemClock.elapsedRealtime() - started} ms")

		assertEquals(32, first.size)
		assertArrayEquals(first, Argon2.hash("correct horse battery staple", salt, Argon2.Parameters.floor))
	}

	@Test
	fun theSaltAndThePasswordBothChangeTheKey() {
		val key = Argon2.hash("password", salt, cheap)

		assertFalse(key.contentEquals(Argon2.hash("password", salt.reversedArray(), cheap)))
		assertFalse(key.contentEquals(Argon2.hash("passwort", salt, cheap)))
	}

	@Test
	fun parametersArgon2RefusesAreReportedWithItsCodeAndMessage() {
		val noPasses = assertThrows(Argon2.Rejected::class.java) { Argon2.hash("password", salt, cheap.copy(t = 0)) }
		val shortSalt = assertThrows(Argon2.Rejected::class.java) { Argon2.hash("password", ByteArray(7), cheap) }

		assertEquals(-12, noPasses.code)
		assertEquals("Time cost is too small", noPasses.message)
		assertEquals(-6, shortSalt.code)
		assertEquals("Salt is too short", shortSalt.message)
	}

	@Test
	fun memoryTheDeviceCannotGiveIsRejectedNotACrash() {
		val rejected = assertThrows(Argon2.Rejected::class.java) { Argon2.hash("password", salt, cheap.copy(m = Int.MAX_VALUE)) }

		assertEquals(-22, rejected.code)
	}
}
