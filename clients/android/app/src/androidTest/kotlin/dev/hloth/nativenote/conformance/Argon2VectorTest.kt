package dev.hloth.nativenote.conformance

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.crypto.Argon2
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Argon2VectorTest {
	@Test
	fun matchesTheReferenceImplementation() {
		for (vector in Vectors.load(VectorFile.Argon2)) {
			val password = vector.string("password")
			assertArrayEquals("case ${vector.name}", vector.bytes("passwordUtf8"), password.encodeToByteArray())

			val out = Argon2.hash(
				password = password,
				salt = vector.bytes("salt"),
				parameters = Argon2.Parameters(m = vector.int("m"), t = vector.int("t"), p = vector.int("p")),
				length = vector.int("length"),
			)

			assertArrayEquals("case ${vector.name}", vector.bytes("output"), out)
		}
	}
}
