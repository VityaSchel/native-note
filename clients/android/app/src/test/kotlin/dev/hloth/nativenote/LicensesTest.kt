package dev.hloth.nativenote

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class LicensesTest {
	private val repository = File("../../..").canonicalFile
	private val notices = File("src/main/assets/licenses.txt").readText().flattened()

	private fun String.flattened() = replace(Regex("\\s+"), " ").trim()

	private fun source(path: String) = File(repository, path).readText()

	private fun String.between(start: String, end: String, inclusive: Boolean = true): String {
		val from = indexOf(start).also { check(it >= 0) { "no $start" } }
		val to = indexOf(end, from).also { check(it >= 0) { "no $end" } }
		return if (inclusive) substring(from, to + end.length) else substring(from + start.length, to)
	}

	private fun assertQuoted(text: String) = assertTrue(text.take(80), text.flattened() in notices)

	@Test
	fun theNoticesQuoteTheSQLCipherLicenseThatBinaryCopiesMustReproduce() {
		assertQuoted(source("clients/macos/native-note-kit/sqlcipher/LICENSE.md"))
	}

	@Test
	fun theNoticesQuoteArgon2AndLibTomCryptFromTheirPinnedSources() {
		val argon2 = source("clients/android/argon2/LICENSE")
		assertQuoted(argon2.substring(0, argon2.indexOf("The terms of the licenses are reproduced below.")))
		assertQuoted(source("clients/android/libtomcrypt/LICENSE").between("[LICENSE #1]", "[/LICENSE #1]", inclusive = false))
	}

	@Test
	fun theNoticesCarryTheApacheLicenseTermsVerbatim() {
		assertQuoted(source("clients/android/argon2/LICENSE").between("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION", "of your accepting any such warranty or additional liability."))
	}

	@Test
	fun everyDeclaredDependencyIsNamedInTheNotices() {
		val families = mapOf("androidx." to "AndroidX", "org.jetbrains.kotlinx" to "kotlinx.coroutines")
		val groups = Regex("""implementation\("([^:"]+):""").findAll(File("build.gradle.kts").readText()).map { it.groupValues[1] }.toList()

		assertTrue(groups.isNotEmpty())
		for (group in groups) {
			val family = families.entries.firstOrNull { group.startsWith(it.key) }?.value
			assertTrue("$group has no entry in licenses.txt", family != null && family in notices)
		}
	}
}
