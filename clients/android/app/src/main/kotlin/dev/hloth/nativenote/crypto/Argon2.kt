package dev.hloth.nativenote.crypto

object Argon2 {
	data class Parameters(val m: Int, val t: Int, val p: Int) {
		companion object {
			val floor = Parameters(m = 256 * 1024, t = 3, p = 4)
		}
	}

	class Rejected(val code: Int, message: String) : Exception(message)

	init {
		System.loadLibrary("argon2")
	}

	fun hash(password: String, salt: ByteArray, parameters: Parameters, length: Int = 32): ByteArray {
		val passwordBytes = password.encodeToByteArray()
		try {
			val out = ByteArray(length)
			val code = hashId(passwordBytes, salt, parameters.m, parameters.t, parameters.p, out)
			if (code != 0) throw Rejected(code, errorMessage(code))
			return out
		} finally {
			passwordBytes.fill(0)
		}
	}

	@JvmStatic
	private external fun hashId(password: ByteArray, salt: ByteArray, m: Int, t: Int, p: Int, out: ByteArray): Int

	@JvmStatic
	private external fun errorMessage(code: Int): String
}
