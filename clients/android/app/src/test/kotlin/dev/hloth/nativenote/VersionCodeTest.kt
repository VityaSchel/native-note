package dev.hloth.nativenote

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VersionCodeTest {
	private val buildScript = File("build.gradle.kts").readText()

	@Test
	fun versionCodeIsTheLiteralFormulaOfTheVersionName() {
		val (major, minor, patch) = Regex("""versionName = "(\d+)\.(\d+)\.(\d+)"""").find(buildScript)!!.destructured.toList().map(String::toInt)
		val versionCode = Regex("""versionCode = (\d+)\n""").find(buildScript)!!.groupValues[1].toInt()

		assertTrue(minor < 100 && patch < 100)
		assertEquals(major * 10000 + minor * 100 + patch, versionCode)
	}
}
