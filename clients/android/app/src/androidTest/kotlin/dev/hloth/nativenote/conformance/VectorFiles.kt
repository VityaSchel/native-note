package dev.hloth.nativenote.conformance

import androidx.test.platform.app.InstrumentationRegistry

object VectorFiles {
	private val instrumentation = InstrumentationRegistry.getInstrumentation()

	fun read(fileName: String) = instrumentation.context.assets.open("vectors/$fileName").bufferedReader().use { it.readText() }

	fun names() = instrumentation.context.assets.list("vectors").orEmpty().toSet()

	fun wordlist() = instrumentation.targetContext.assets.open("english.txt").use { it.readBytes() }
}
