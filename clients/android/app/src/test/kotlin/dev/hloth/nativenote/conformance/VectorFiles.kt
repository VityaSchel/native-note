package dev.hloth.nativenote.conformance

import java.io.File

object VectorFiles {
	private val spec = File("../../../spec")

	fun read(fileName: String) = File(spec, "vectors/$fileName").readText()

	fun names() = File(spec, "vectors").list().orEmpty().toSet()

	fun wordlist() = File(spec, "wordlists/english.txt").readBytes()
}
