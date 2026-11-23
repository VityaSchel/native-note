package dev.hloth.nativenote.threatmodel

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePinsTest {
	private val repository = File("../../..").canonicalFile

	private fun checkedOut(path: String): String {
		val git = ProcessBuilder("git", "-C", File(repository, path).path, "rev-parse", "HEAD").redirectErrorStream(true).start()
		return git.inputStream.bufferedReader().readText().trim().also { assertEquals("git rev-parse in $path", 0, git.waitFor()) }
	}

	@Test
	fun everyCLibraryIsBuiltFromAPinnedRevision() {
		val design = File(repository, "clients/android/DESIGN.md").readText()
		for ((path, name) in listOf("clients/android/argon2" to "phc-winner-argon2", "clients/android/libtomcrypt" to "LibTomCrypt")) {
			val revision = Regex("\\[$name]\\([^)]*\\): revision `([0-9a-f]{7,40})`").find(design)?.groupValues?.get(1)
			assertTrue("DESIGN.md pins $name", revision != null)
			assertTrue("$path is checked out at $revision", checkedOut(path).startsWith(revision!!))
		}

		val kit = File(repository, "clients/macos/native-note-kit")
		val script = File(kit, "Scripts/sqlcipher-amalgamation.sh").readLines()
		fun pinned(name: String) = script.first { it.startsWith("$name=\"") }.substringAfter('"').substringBefore('"')
		assertEquals(pinned("commit"), checkedOut("clients/macos/native-note-kit/sqlcipher"))
		assertEquals(64, pinned("sqlite3_c_sha256").length)
		val cmake = File(repository, "clients/android/app/src/main/cpp/CMakeLists.txt").readText()
		assertTrue(cmake.contains("SQLCIPHER_CRYPTO_LIBTOMCRYPT"))
	}
}
