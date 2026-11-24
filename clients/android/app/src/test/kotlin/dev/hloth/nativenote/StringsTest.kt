package dev.hloth.nativenote

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

class StringsTest {
	@Test
	fun noTextCallsATabletAPhone() {
		val strings = Regex("<(?:string|item)[^>]*>([^<]*)<").findAll(File("src/main/res/values/strings.xml").readText()).map { it.groupValues[1] }

		assertEquals(emptyList<String>(), strings.filter { "phone" in it.lowercase() }.toList())
	}
}
