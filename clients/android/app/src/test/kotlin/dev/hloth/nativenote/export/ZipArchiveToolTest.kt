package dev.hloth.nativenote.export

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ZipArchiveToolTest {
	@get:Rule
	val temporary = TemporaryFolder()

	@Test
	fun unzipFindsNoErrorsAndExtractsIdenticalBytes() {
		val unzip = tool("unzip")
		val archive = temporary.newFile("export.zip")
		val extracted = File(temporary.root, "extracted")
		archive.writeBytes(ZipArchive.write(ZipSample.entries))

		val test = runTool(unzip, listOf("-t", archive.path))
		assertEquals(test.output, 0, test.status)
		assertTrue(test.output, "No errors detected in compressed data" in test.output)
		assertEquals(0, runTool(unzip, listOf("-q", archive.path, "-d", extracted.path)).status)
		for (entry in ZipSample.entries) {
			assertArrayEquals(entry.name, entry.data, File(extracted, entry.name).readBytes())
		}
		assertEquals(ZipSample.entries.size, extracted.walk().count { it.isFile })
	}

	@Test
	fun zipinfoListsEveryEntryAsStoredWithItsUTCTime() {
		val zipinfo = tool("zipinfo")
		val archive = temporary.newFile("export.zip")
		archive.writeBytes(ZipArchive.write(ZipSample.entries))
		val total = ZipSample.entries.sumOf { it.data.size }

		val listing = runTool(zipinfo, listOf("-T", archive.path))
		assertEquals(listing.output, 0, listing.status)
		for (line in listOf(
			"number of entries: 3",
			"stor 20251009.085320 Groceries.md",
			"stor 20251009.085322 Empty.md",
			"stor 20251010.085320 Journal/",
			"3 files, $total bytes uncompressed, $total bytes compressed",
		)) {
			assertTrue("$line in ${listing.output}", line in listing.output)
		}
	}

	@Test
	fun readsStoredArchivesMadeByZip() {
		val zip = tool("zip")
		val directory = temporary.root
		val files = listOf(
			"a.md" to "hello".encodeToByteArray(),
			"empty.md" to ByteArray(0),
			"sub/\u0417\u0430\u043C\u0435\u0442\u043A\u0438 \u2713.md" to "x".encodeToByteArray(),
			"sub/binary.bin" to ByteArray(256) { it.toByte() },
		)
		for ((name, data) in files) {
			File(directory, name).apply { parentFile?.mkdirs() }.writeBytes(data)
		}

		val run = runTool(zip, listOf("-0", "-D", "-z", "archive.zip") + files.map { it.first }, directory, "made by Info-ZIP\n")
		val entries = ZipArchive.read(File(directory, "archive.zip").readBytes())

		assertEquals(run.output, 0, run.status)
		assertEquals(files.map { it.first }, entries.map { it.name })
		assertEquals(files.map { it.second.toList() }, entries.map { it.data.toList() })
	}

	@Test
	fun rejectsDeflatedEntriesMadeByZip() {
		val zip = tool("zip")
		val directory = temporary.root
		File(directory, "long.md").writeText("compressible ".repeat(1_000))

		assertEquals(0, runTool(zip, listOf("-6", "archive.zip", "long.md"), directory).status)
		assertThrows(ZipArchive.Failure.Unsupported::class.java) {
			ZipArchive.read(File(directory, "archive.zip").readBytes())
		}
	}

	private class ToolRun(val status: Int, val output: String)

	private fun tool(name: String): String {
		val directories = System.getenv("PATH").orEmpty().split(File.pathSeparator) + listOf("/usr/bin", "/bin")
		val path = directories.filter { it.isNotEmpty() }.map { File(it, name) }.firstOrNull { it.canExecute() }?.path
		assumeTrue("$name is not installed", path != null)
		return checkNotNull(path)
	}

	private fun runTool(tool: String, arguments: List<String>, directory: File? = null, input: String? = null): ToolRun {
		val process = ProcessBuilder(listOf(tool) + arguments).apply {
			directory(directory)
			redirectErrorStream(true)
			environment().apply {
				clear()
				put("LC_ALL", "en_US.UTF-8")
				put("PATH", "/usr/bin:/bin")
				put("TMPDIR", temporary.root.path)
			}
		}.start()
		process.outputStream.use { stream -> input?.let { stream.write(it.encodeToByteArray()) } }
		val output = process.inputStream.use { it.readBytes() }.decodeToString()
		return ToolRun(process.waitFor(), output)
	}
}
