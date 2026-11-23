package dev.hloth.nativenote.conformance

import org.junit.Assert.assertEquals
import org.junit.Test

class VectorCoverageTest {
	@Test
	fun everyBundledFileIsListed() {
		assertEquals(VectorFile.entries.map { it.fileName }.toSet(), VectorFiles.names())
	}
}
