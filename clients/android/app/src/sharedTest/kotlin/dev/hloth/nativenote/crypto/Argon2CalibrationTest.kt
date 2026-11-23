package dev.hloth.nativenote.crypto

import kotlin.math.pow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class Argon2CalibrationTest {
	private val floor = Argon2.Parameters.floor

	private class Curve(val seconds: (Int) -> Double) {
		val measured = mutableListOf<Int>()

		fun measure(parameters: Argon2.Parameters): Double {
			measured += parameters.m
			return seconds(parameters.m)
		}
	}

	private fun nonlinear(memory: Int) = 0.14 * (memory.toDouble() / floor.m).pow(1.35)

	@Test
	fun keepsTheFloorWhenItAlreadyCostsTheTarget() {
		val curve = Curve { 2.0 }

		assertEquals(floor, Argon2Calibration.calibrateMemory(target = 1.0, measure = curve::measure))
		assertEquals(listOf(floor.m), curve.measured)
	}

	@Test
	fun landsJustUnderTheTargetOnACurveThatIsNotLinear() {
		val curve = Curve(::nonlinear)

		val parameters = Argon2Calibration.calibrateMemory(target = 1.0, measure = curve::measure)

		assertTrue(nonlinear(parameters.m) <= 1.0)
		assertTrue(nonlinear(parameters.m) > 0.9)
		assertTrue(curve.measured.size <= 5)
		assertEquals(floor.t, parameters.t)
		assertEquals(floor.p, parameters.p)
		assertEquals(0, parameters.m % (8 * parameters.p))
	}

	@Test
	fun aimsAnInProcessRunAtFourTenthsOfASecond() {
		val parameters = Argon2Calibration.calibrateMemory(measure = Curve(::nonlinear)::measure)

		assertTrue(nonlinear(parameters.m) <= 0.4)
		assertTrue(nonlinear(parameters.m) > 0.35)
	}

	@Test
	fun neverKeepsMemoryThatMeasuredOverTheTarget() {
		val parameters = Argon2Calibration.calibrateMemory(target = 1.0, measure = Curve { if (it > 700 * 1024) 1.4 else 0.2 }::measure)

		assertTrue(parameters.m <= 700 * 1024)
		assertTrue(parameters.m > floor.m)
	}

	@Test
	fun neverMeasuresPastTheMemoryLimit() {
		val curve = Curve { 0.001 }

		val parameters = Argon2Calibration.calibrateMemory(target = 1.0, limit = 512 * 1024, measure = curve::measure)

		assertEquals(512 * 1024, parameters.m)
		assertTrue(curve.measured.all { it <= 512 * 1024 })
	}

	@Test
	fun stopsAtTwoGibibytesByDefault() {
		val curve = Curve { 0.001 }

		val parameters = Argon2Calibration.calibrateMemory(measure = curve::measure)

		assertEquals(2 * 1024 * 1024, parameters.m)
		assertTrue(curve.measured.all { it <= 2 * 1024 * 1024 })
	}

	@Test
	fun scalesALinearCurveStraightToFourTenthsOfASecond() {
		val curve = Curve { 0.2 * it / floor.m }

		val parameters = Argon2Calibration.calibrateMemory(measure = curve::measure)

		assertEquals(2 * floor.m, parameters.m)
		assertEquals(listOf(floor.m, 2 * floor.m), curve.measured)
	}

	@Test
	fun distrustsACandidateThatTookNoTime() {
		assertEquals(floor, Argon2Calibration.calibrateMemory(measure = Curve { if (it == floor.m) 0.2 else 0.0 }::measure))
	}

	@Test
	fun keepsTheFloorWhenTheClockDidNotAdvance() {
		for (reading in listOf(0.0, -1.0)) {
			val curve = Curve { reading }

			assertEquals(floor, Argon2Calibration.calibrateMemory(measure = curve::measure))
			assertEquals(listOf(floor.m), curve.measured)
		}
	}
}
