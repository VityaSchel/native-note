package dev.hloth.nativenote.export

import dev.hloth.nativenote.export.ZipArchive.Failure
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.util.TimeZone
import java.util.zip.CRC32
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ZipArchiveTest {
	@Test
	fun keepsUtcTimesThatFallInALocalDaylightSavingGap() {
		val zone = TimeZone.getDefault()
		TimeZone.setDefault(TimeZone.getTimeZone("Europe/Madrid"))
		try {
			val gap = Instant.parse("2025-03-30T02:30:00Z").toEpochMilli()

			assertEquals(gap, modifiedAfterRoundTrip(gap))
		} finally {
			TimeZone.setDefault(zone)
		}
	}

	@Test
	fun writesNoExtraFieldForAnyTimeItCanHold() {
		for (moment in listOf(Instant.parse("2105-06-01T00:00:00Z").toEpochMilli(), Long.MAX_VALUE, Long.MIN_VALUE)) {
			val archive = ZipArchive.write(listOf(ZipEntry("a.md", byteArrayOf(1), moment)))

			assertEquals(0, archive[28].toInt() or (archive[29].toInt() shl 8))
		}
	}

	@Test
	fun roundTripsNamesBytesAndModificationTimes() {
		assertEntries(ZipSample.entries, ZipArchive.read(ZipArchive.write(ZipSample.entries)))
	}

	@Test
	fun roundTripsAnArchiveWithNoEntries() {
		val archive = ZipArchive.write(emptyList())

		assertEquals(22, archive.size)
		assertTrue(ZipArchive.read(archive).isEmpty())
	}

	@Test
	fun roundTripsThousandsOfEntries() {
		val random = Random(1)
		val entries = List(3_000) { index ->
			ZipEntry("notes/$index.md", random.nextBytes(random.nextInt(0, 65)), MOMENT + 2_000L * index)
		}

		assertEntries(entries, ZipArchive.read(ZipArchive.write(entries)))
	}

	@Test
	fun writesIdenticalBytesForIdenticalEntries() {
		assertArrayEquals(ZipArchive.write(ZipSample.entries), ZipArchive.write(ZipSample.entries))
	}

	@Test
	fun writesStoredUTF8EntriesWithUTCTimesAndNoExtraFields() {
		val expected = handBuiltArchive(NOTE.name.encodeToByteArray(), NOTE.data)

		assertArrayEquals(withoutFreeFields(expected), withoutFreeFields(ZipArchive.write(listOf(NOTE))))
	}

	@Test
	fun readsPastAnArchiveComment() {
		val archive = ZipArchive.write(ZipSample.entries)
		val decoy = "exported PK\u0005\u0006 by hand, a signature followed by more than a record's worth of text".encodeToByteArray()
		for (comment in listOf(ByteArray(0), decoy, ByteArray(0xFFFF) { 0x50 })) {
			val commented = archive.withU16(archive.size - 2, comment.size) + comment

			assertEntries(ZipSample.entries, ZipArchive.read(commented))
		}
	}

	@Test
	fun readsPastEntryComments() {
		val archive = ZipArchive.write(ZipSample.entries)
		val central = ZipSample.entries.sumOf { 30 + it.name.encodeToByteArray().size + it.data.size }
		val firstRecordEnd = central + 46 + ZipSample.entries[0].name.encodeToByteArray().size
		val comment = "an entry comment".encodeToByteArray()
		val end = archive.size - 22
		val commented = archive.withU16(central + 32, comment.size).copyOf(firstRecordEnd) + comment +
			archive.copyOfRange(firstRecordEnd, end) +
			archive.copyOfRange(end, archive.size).withU32(12, (end - central + comment.size).toLong())

		assertEntries(ZipSample.entries, ZipArchive.read(commented))
	}

	@Test
	fun roundsModificationTimesDownToEvenSeconds() {
		assertEquals(MOMENT, modifiedAfterRoundTrip(MOMENT + 1_900))
		assertEquals(MOMENT + 2_000, modifiedAfterRoundTrip(MOMENT + 2_500))
	}

	@Test
	fun clampsModificationTimesToTheRangeMSDOSCanHold() {
		val earliest = Instant.parse("1980-01-01T00:00:00Z").toEpochMilli()
		val latest = Instant.parse("2107-12-31T23:59:58Z").toEpochMilli()

		assertEquals(earliest, modifiedAfterRoundTrip(earliest))
		assertEquals(latest, modifiedAfterRoundTrip(latest))
		assertEquals(earliest, modifiedAfterRoundTrip(0))
		assertEquals(earliest, modifiedAfterRoundTrip(Long.MIN_VALUE))
		assertEquals(latest, modifiedAfterRoundTrip(Long.MAX_VALUE))
	}

	@Test
	fun computesTheIEEECRC32() {
		val cases = listOf(
			"" to 0x0000_0000L,
			"a" to 0xE8B7_BE43L,
			"123456789" to 0xCBF4_3926L,
			"The quick brown fox jumps over the lazy dog" to 0x414F_A339L,
		)
		for ((text, checksum) in cases) {
			val archive = ZipArchive.write(listOf(ZipEntry("a.md", text.encodeToByteArray(), MOMENT)))

			assertEquals(text, checksum, archive.u32(14))
			assertEquals(text, checksum, archive.u32(30 + 4 + text.length + 16))
		}
	}

	@Test
	fun refusesToWriteUnsafeNames() {
		for (name in UNSAFE_NAMES) {
			assertThrows(name, Failure.UnsafeName::class.java) { ZipArchive.write(listOf(ZipEntry(name, ByteArray(0), MOMENT))) }
		}
	}

	@Test
	fun refusesToReadUnsafeNames() {
		for (name in UNSAFE_NAMES) {
			assertThrows(name, Failure.UnsafeName::class.java) { ZipArchive.read(handBuiltArchive(name.encodeToByteArray())) }
		}
	}

	@Test
	fun refusesToReadNamesThatAreNotUTF8() {
		assertThrows(Failure.UnsafeName::class.java) {
			ZipArchive.read(handBuiltArchive(byteArrayOf(0x6E, 0xFF.toByte(), 0x2E, 0x6D, 0x64)))
		}
	}

	@Test
	fun rejectsDataThatIsNotAZip() {
		val random = Random(2)
		for (data in listOf(ByteArray(0), "hello".encodeToByteArray(), ByteArray(100), random.nextBytes(4_096))) {
			assertThrows(Failure.NotAZip::class.java) { ZipArchive.read(data) }
		}
	}

	@Test
	fun rejectsATruncatedArchive() {
		val archive = ZipArchive.write(ZipSample.entries)
		for (length in listOf(4, 30, archive.size / 2, archive.size - 22, archive.size - 1)) {
			assertThrows("length $length", Failure.Damaged::class.java) { ZipArchive.read(archive.copyOf(length)) }
		}
	}

	@Test
	fun rejectsAFlippedDataByte() {
		val archive = ZipArchive.write(listOf(NOTE))
		val flipped = archive.withU8(30 + 7 + 4, archive[30 + 7 + 4].toInt() xor 0x01)

		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(flipped) }
	}

	@Test
	fun rejectsACentralDirectoryOffsetOrSizePastTheEnd() {
		val archive = ZipArchive.write(listOf(NOTE))
		val end = archive.size - 22

		for (field in listOf(end + 12, end + 16)) {
			assertThrows("field $field", Failure.Damaged::class.java) { ZipArchive.read(archive.withU32(field, 0x7FFF_0000)) }
		}
	}

	@Test
	fun rejectsAnEntrySizeOrLocalOffsetPastTheEnd() {
		val archive = ZipArchive.write(listOf(NOTE))
		val central = NOTE_CENTRAL_DIRECTORY
		val huge = 0x7FFF_0000L
		val centralSizes = archive.withU32(central + 20, huge).withU32(central + 24, huge)
		val bothSizes = centralSizes.withU32(18, huge).withU32(22, huge)

		for (damaged in listOf(centralSizes, bothSizes, archive.withU32(central + 42, huge))) {
			assertThrows(Failure.Damaged::class.java) { ZipArchive.read(damaged) }
		}
	}

	@Test
	fun rejectsEntryDataThatRunsIntoTheCentralDirectory() {
		val archive = handBuiltArchive("a.md".encodeToByteArray())
		val central = 38
		val reach = 4L + 16
		val crc = crc32(archive.copyOfRange(34, central + 16))
		val damaged = archive
			.withU32(14, crc).withU32(18, reach).withU32(22, reach)
			.withU32(central + 16, crc).withU32(central + 20, reach).withU32(central + 24, reach)

		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(damaged) }
	}

	@Test
	fun rejectsALocalHeaderThatDisagreesWithTheCentralDirectory() {
		val archive = ZipArchive.write(listOf(NOTE))

		for (damaged in listOf(archive.withU16(10, 0), archive.withU32(0, 0), archive.withU8(30, 0x4E))) {
			assertThrows(Failure.Damaged::class.java) { ZipArchive.read(damaged) }
		}
	}

	@Test
	fun rejectsAStoredEntryWhoseSizesDisagree() {
		val archive = handBuiltArchive("a.md".encodeToByteArray())

		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(archive.withU32(22, 5).withU32(38 + 24, 5)) }
	}

	@Test
	fun rejectsACentralHeaderWithoutItsSignature() {
		assertThrows(Failure.Damaged::class.java) {
			ZipArchive.read(handBuiltArchive("a.md".encodeToByteArray()).withU8(38, 0))
		}
	}

	@Test
	fun rejectsACentralDirectoryWithBytesPastItsEntries() {
		val archive = handBuiltArchive("a.md".encodeToByteArray())
		val end = archive.size - 22
		val padded = archive.copyOf(end) + ByteArray(4) + archive.copyOfRange(end, archive.size).withU32(12, (end - 38 + 4).toLong())

		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(padded) }
	}

	@Test
	fun rejectsTwoEntriesSharingTheSameBytes() {
		val archive = ZipArchive.write(listOf(NOTE))
		val central = NOTE_CENTRAL_DIRECTORY
		val entry = archive.copyOfRange(central, archive.size - 22)
		val end = archive.copyOfRange(archive.size - 22, archive.size)
			.withU16(8, 2)
			.withU16(10, 2)
			.withU32(12, 2L * entry.size)

		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(archive.copyOf(central) + entry + entry + end) }
	}

	@Test
	fun rejectsEncryptionDataDescriptorsCompressionAndUnknownFlags() {
		val name = "a.md".encodeToByteArray()
		val archives = listOf(
			handBuiltArchive(name, flags = 0x0801),
			handBuiltArchive(name, flags = 0x0841, method = 99),
			handBuiltArchive(name, flags = 0x0808),
			handBuiltArchive(name, flags = 0x0820),
			handBuiltArchive(name, method = 8),
		)

		for ((index, archive) in archives.withIndex()) {
			assertThrows("case $index", Failure.Unsupported::class.java) { ZipArchive.read(archive) }
		}
	}

	@Test
	fun rejectsStrongAndCentralDirectoryEncryption() {
		for (flags in listOf(0x0840, 0x2800)) {
			assertThrows("flags $flags", Failure.Unsupported::class.java) {
				ZipArchive.read(handBuiltArchive("a.md".encodeToByteArray(), flags = flags))
			}
		}
	}

	@Test
	fun rejectsZip64Archives() {
		val archive = ZipArchive.write(listOf(NOTE))
		val end = archive.size - 22
		val endRecord = archive.copyOfRange(end, archive.size)
		val locator = LittleEndian().u32(ZIP64_LOCATOR_SIGNATURE).u32(0).u64(0).u32(1).bytes

		assertThrows(Failure.Unsupported::class.java) {
			ZipArchive.read(archive.withU16(end + 8, 0xFFFF).withU16(end + 10, 0xFFFF))
		}
		assertThrows(Failure.Unsupported::class.java) {
			ZipArchive.read(archive.withU32(NOTE_CENTRAL_DIRECTORY + 42, 0xFFFF_FFFFL))
		}
		assertThrows(Failure.Unsupported::class.java) { ZipArchive.read(archive.copyOf(end) + locator + endRecord) }
		assertThrows(Failure.Damaged::class.java) { ZipArchive.read(archive.copyOf(end) + ByteArray(20) + endRecord) }
	}

	@Test
	fun rejectsEveryZip64Sentinel() {
		val archive = handBuiltArchive("a.md".encodeToByteArray())
		val end = archive.size - 22

		for (field in listOf(38 + 20, 38 + 24, end + 12, end + 16)) {
			assertThrows("field $field", Failure.Unsupported::class.java) { ZipArchive.read(archive.withU32(field, 0xFFFF_FFFFL)) }
		}
	}

	@Test
	fun rejectsEveryDiskFieldOfASpannedArchive() {
		val archive = handBuiltArchive("a.md".encodeToByteArray())
		val end = archive.size - 22
		val spanned = listOf(
			archive.withU16(end + 4, 1), archive.withU16(end + 6, 1),
			archive.withU16(end + 8, 2), archive.withU16(38 + 34, 1),
		)

		for ((index, damaged) in spanned.withIndex()) {
			assertThrows("case $index", Failure.Unsupported::class.java) { ZipArchive.read(damaged) }
		}
	}

	@Test
	fun refusesMoreEntriesThanAPlainZipCounts() {
		val empty = ZipEntry("n", ByteArray(0), MOMENT)

		assertEquals(65_534, ZipArchive.read(ZipArchive.write(List(65_534) { empty })).size)
		assertThrows(Failure.TooLarge::class.java) { ZipArchive.write(List(65_535) { empty }) }
	}

	@Test
	fun refusesSizesAndOffsetsThatNeedZip64() {
		for (directoryOffset in listOf(0xFFFF_FFFFL + 31, 0xFFFF_FFFFL)) {
			assertThrows("offset $directoryOffset", Failure.TooLarge::class.java) { ZipArchive.write(entriesReaching(directoryOffset)) }
		}
	}

	@Test
	fun keepsNamesUpToTheLengthFieldAndRefusesLonger() {
		val longest = ZipEntry("n".repeat(0xFFFF), ByteArray(0), MOMENT)
		val tooLong = ZipEntry("n".repeat(0x1_0000), ByteArray(0), MOMENT)

		assertEntries(listOf(longest), ZipArchive.read(ZipArchive.write(listOf(longest))))
		assertThrows(Failure.TooLarge::class.java) { ZipArchive.write(listOf(tooLong)) }
	}

	@Test
	fun throwsOnlyZipFailuresForThousandsOfRandomMutations() {
		val original = ZipArchive.write(ZipSample.entries)
		val random = Random(3)
		repeat(5_000) {
			var mutated = original
			repeat(random.nextInt(1, 4)) { mutated = mutated.mutated(random) }
			assertOnlyZipFailures(mutated)
		}
	}

	@Test
	fun throwsOnlyZipFailuresWhenAnySingleByteChanges() {
		val original = ZipArchive.write(ZipSample.entries)
		for (offset in original.indices) {
			for (value in listOf(0x00, 0x01, 0x7F, 0x80, 0xFF, original[offset].toInt().inv())) {
				assertOnlyZipFailures(original.withU8(offset, value))
			}
		}
	}

	private class LittleEndian {
		private val output = ByteArrayOutputStream()

		val bytes: ByteArray get() = output.toByteArray()

		fun u16(value: Int) = integer(value.toLong(), 2)

		fun u32(value: Long) = integer(value, 4)

		fun u64(value: Long) = integer(value, 8)

		fun append(value: ByteArray) = apply { output.write(value, 0, value.size) }

		private fun integer(value: Long, width: Int) = apply { repeat(width) { output.write((value shr (8 * it)).toInt()) } }
	}

	private fun assertEntries(expected: List<ZipEntry>, actual: List<ZipEntry>) {
		assertEquals(ZipSample.fields(expected), ZipSample.fields(actual))
	}

	private fun assertOnlyZipFailures(archive: ByteArray) {
		val failure = runCatching { ZipArchive.read(archive) }.exceptionOrNull()
		if (failure != null && failure !is Failure) throw AssertionError("unexpected $failure reading ${archive.toHexString()}", failure)
	}

	private fun modifiedAfterRoundTrip(modified: Long) =
		ZipArchive.read(ZipArchive.write(listOf(ZipEntry("a.md", ByteArray(0), modified)))).single().modified

	private fun entriesReaching(directoryOffset: Long): List<ZipEntry> {
		val block = ByteArray(1 shl 20)
		val header = 30 + 5
		val count = directoryOffset / (header + block.size)
		val rest = ByteArray((directoryOffset - count * (header + block.size) - header).toInt())
		return List(count.toInt() + 1) { index -> ZipEntry(index.toString().padStart(5, '0'), if (index < count) block else rest, MOMENT) }
	}

	private fun withoutFreeFields(archive: ByteArray) = archive
		.withU16(4, 0)
		.withU16(NOTE_CENTRAL_DIRECTORY + 4, 0)
		.withU16(NOTE_CENTRAL_DIRECTORY + 6, 0)
		.withU16(NOTE_CENTRAL_DIRECTORY + 36, 0)
		.withU32(NOTE_CENTRAL_DIRECTORY + 38, 0)

	private fun handBuiltArchive(name: ByteArray, data: ByteArray = "body".encodeToByteArray(), flags: Int = 0x0800, method: Int = 0): ByteArray {
		val time = (8 shl 11) or (53 shl 5) or (20 / 2)
		val date = ((2025 - 1980) shl 9) or (10 shl 5) or 9
		val size = data.size.toLong()
		val unixRegularFile = 0x81A4L shl 16
		val fields = LittleEndian().u16(20).u16(flags).u16(method).u16(time).u16(date).u32(crc32(data)).u32(size).u32(size)
			.u16(name.size).u16(0).bytes
		val local = LittleEndian().u32(LOCAL_SIGNATURE).append(fields).append(name).append(data).bytes
		val central = LittleEndian().u32(CENTRAL_SIGNATURE).u16(0x0314).append(fields)
			.u16(0).u16(0).u16(0).u32(unixRegularFile).u32(0).append(name).bytes
		val end = LittleEndian().u32(END_SIGNATURE).u16(0).u16(0).u16(1).u16(1)
			.u32(central.size.toLong()).u32(local.size.toLong()).u16(0).bytes
		return local + central + end
	}

	private fun crc32(bytes: ByteArray) = CRC32().apply { update(bytes) }.value

	private fun ByteArray.mutated(random: Random): ByteArray {
		if (isEmpty()) return random.nextBytes(22)
		val offset = random.nextInt(size)
		val length = random.nextInt(1, 17)
		return when (random.nextInt(6)) {
			0 -> withU8(offset, this[offset].toInt() xor (1 shl random.nextInt(8)))
			1 -> withU8(offset, random.nextInt(256))
			2 -> copyOf().also { it.fill(EXTREMES[random.nextInt(EXTREMES.size)], offset, minOf(size, offset + 4)) }
			3 -> copyOf(offset)
			4 -> copyOf(offset) + copyOfRange(minOf(size, offset + length), size)
			else -> copyOf(offset) + random.nextBytes(length) + copyOfRange(offset, size)
		}
	}

	private fun ByteArray.patched(at: Int, value: Long, width: Int) = copyOf().also { patched ->
		repeat(width) { patched[at + it] = (value shr (8 * it)).toByte() }
	}

	private fun ByteArray.withU8(at: Int, value: Int) = patched(at, value.toLong(), 1)

	private fun ByteArray.withU16(at: Int, value: Int) = patched(at, value.toLong(), 2)

	private fun ByteArray.withU32(at: Int, value: Long) = patched(at, value, 4)

	private fun ByteArray.u32(at: Int) = (0 until 4).fold(0L) { value, index -> value or ((this[at + index].toLong() and 0xFF) shl (8 * index)) }

	private companion object {
		const val MOMENT = ZipSample.MOMENT
		const val NOTE_CENTRAL_DIRECTORY = 30 + 7 + 9
		const val LOCAL_SIGNATURE = 0x0403_4B50L
		const val CENTRAL_SIGNATURE = 0x0201_4B50L
		const val END_SIGNATURE = 0x0605_4B50L
		const val ZIP64_LOCATOR_SIGNATURE = 0x0706_4B50L

		val NOTE = ZipEntry("note.md", "body text".encodeToByteArray(), MOMENT)

		val EXTREMES = listOf(0x00, 0x7F, 0x80, 0xFF).map { it.toByte() }

		val UNSAFE_NAMES = listOf(
			"", "/etc/passwd", "..", "../escape.md", "notes/../../escape.md", "notes/..", "./note.md",
			"notes//note.md", "notes/", "notes\\note.md", "note\u0000.md", "notes/../\u0301escape.md", "/\u0301etc",
		)
	}
}
