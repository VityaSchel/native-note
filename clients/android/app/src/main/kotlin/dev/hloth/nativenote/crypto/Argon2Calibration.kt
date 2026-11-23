package dev.hloth.nativenote.crypto

object Argon2Calibration {
	private val floor = Argon2.Parameters.floor

	fun calibrateMemory(
		target: Double = 0.4,
		limit: Int = 2 * 1024 * 1024,
		refinements: Int = 4,
		measure: (Argon2.Parameters) -> Double = ::timedHash,
	): Argon2.Parameters {
		val atFloor = measure(floor)
		if (atFloor <= 0 || atFloor >= target) return floor

		var fitsMemory = floor.m
		var fitsTime = atFloor
		var tooSlow: Int? = null
		for (attempt in 0 until refinements) {
			val estimate = tooSlow?.let { fitsMemory / 2.0 + it / 2.0 } ?: (fitsMemory * target / fitsTime)
			val candidate = aligned(minOf(limit.toDouble(), estimate))
			if (candidate <= fitsMemory || candidate == tooSlow) break
			val time = measure(floor.copy(m = candidate))
			if (time > 0 && time <= target) {
				fitsMemory = candidate
				fitsTime = time
			} else {
				tooSlow = candidate
			}
		}
		return floor.copy(m = fitsMemory)
	}

	private fun aligned(memory: Double): Int {
		val whole = memory.toInt()
		return whole - whole % (8 * floor.p)
	}

	private fun timedHash(parameters: Argon2.Parameters): Double {
		val started = System.nanoTime()
		Argon2.hash("native-note calibration", ByteArray(16), parameters).fill(0)
		return (System.nanoTime() - started) / 1e9
	}
}
