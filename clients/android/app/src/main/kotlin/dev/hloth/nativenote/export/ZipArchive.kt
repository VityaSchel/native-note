package dev.hloth.nativenote.export

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.util.zip.CRC32

class ZipEntry(val name: String, val data: ByteArray, val modified: Long)

object ZipArchive {
	sealed class Failure(message: String) : Exception(message) {
		class NotAZip : Failure("not a zip")

		class Unsupported(feature: String) : Failure("unsupported zip feature: $feature")

		class Damaged(damage: String) : Failure("damaged zip: $damage")

		class UnsafeName : Failure("an unsafe entry name")

		class TooLarge : Failure("too large for one zip")
	}

	fun write(entries: List<ZipEntry>): ByteArray {
		if (entries.size >= MAXIMUM_ENTRIES) throw Failure.TooLarge()
		val names = entries.map { encodedName(it.name) }
		val directoryOffset = names.sumOf { LOCAL_HEADER.toLong() + it.size } + entries.sumOf { it.data.size.toLong() }
		val directorySize = names.sumOf { CENTRAL_HEADER.toLong() + it.size }
		if (directoryOffset >= MAXIMUM_SIZE || directorySize >= MAXIMUM_SIZE || directoryOffset + directorySize + END_RECORD > Int.MAX_VALUE) {
			throw Failure.TooLarge()
		}
		val archive = ByteBuffer.allocate((directoryOffset + directorySize + END_RECORD).toInt()).order(ByteOrder.LITTLE_ENDIAN)
		val directory = ByteBuffer.allocate(directorySize.toInt()).order(ByteOrder.LITTLE_ENDIAN)
		for ((entry, name) in entries.zip(names)) {
			val (time, date) = dosTimestamp(entry.modified)
			val header = Header(UTF8_FLAG, 0, time, date, crc32(entry.data, 0, entry.data.size), entry.data.size.toLong(), entry.data.size.toLong(), name.toList())
			directory.putInt(CENTRAL_SIGNATURE.toInt()).putShort(VERSION_MADE_BY_UNIX.toShort())
			directory.putFields(header, name)
			directory.putShort(0).putShort(0).putShort(0).putInt(REGULAR_FILE_ATTRIBUTES).putInt(archive.position()).put(name)
			archive.putInt(LOCAL_SIGNATURE.toInt())
			archive.putFields(header, name)
			archive.put(name).put(entry.data)
		}
		archive.put(directory.array())
		archive.putInt(END_SIGNATURE.toInt()).putShort(0).putShort(0)
			.putShort(entries.size.toShort()).putShort(entries.size.toShort())
			.putInt(directorySize.toInt()).putInt(directoryOffset.toInt()).putShort(0)
		return archive.array()
	}

	private fun ByteBuffer.putFields(header: Header, name: ByteArray) {
		putShort(VERSION_NEEDED.toShort()).putShort(header.flags.toShort()).putShort(header.method.toShort())
		putShort(header.time.toShort()).putShort(header.date.toShort())
		putInt(header.crc.toInt()).putInt(header.compressedSize.toInt()).putInt(header.size.toInt())
		putShort(name.size.toShort()).putShort(0)
	}

	fun read(archive: ByteArray): List<ZipEntry> {
		val (directoryStart, directoryEnd, count) = centralDirectory(archive)
		val directory = Cursor(archive, directoryStart, directoryEnd)
		val records = List(count) { record(directory, archive, directoryStart) }
		if (directory.position != directoryEnd) throw Failure.Damaged("inconsistent")
		val spans = records.sortedBy { it.start }
		if (spans.zipWithNext().any { (first, second) -> first.end > second.start }) throw Failure.Damaged("overlapping")
		return records.map { record ->
			if (crc32(archive, record.dataStart, record.header.size.toInt()) != record.header.crc) throw Failure.Damaged("checksum")
			ZipEntry(record.name, archive.copyOfRange(record.dataStart, record.end), moment(record.header.time, record.header.date))
		}
	}

	private data class Header(
		val flags: Int,
		val method: Int,
		val time: Int,
		val date: Int,
		val crc: Long,
		val compressedSize: Long,
		val size: Long,
		val name: List<Byte>,
	)

	private class Record(val name: String, val header: Header, val start: Int, val dataStart: Int, val end: Int)

	private fun centralDirectory(archive: ByteArray): Triple<Int, Int, Int> {
		val last = archive.size - END_RECORD
		for (start in last downTo maxOf(0, last - MAXIMUM_COMMENT)) {
			val end = Cursor(archive, start, archive.size)
			if (end.u32() != END_SIGNATURE) continue
			val disk = end.u16()
			val directoryDisk = end.u16()
			val entriesOnDisk = end.u16()
			val entries = end.u16()
			val size = end.u32()
			val offset = end.u32()
			val commentLength = end.u16()
			if (start + END_RECORD + commentLength != archive.size) continue

			if (entries == 0xFFFF || size == 0xFFFF_FFFFL || offset == 0xFFFF_FFFFL) throw Failure.Unsupported("zip64")
			if (disk != 0 || directoryDisk != 0 || entriesOnDisk != entries) throw Failure.Unsupported("multiple disks")
			val directoryEnd = offset + size
			if (directoryEnd > start) throw Failure.Damaged("out of bounds")
			if (directoryEnd != start.toLong()) {
				val locator = runCatching { Cursor(archive, start - ZIP64_LOCATOR, start).u32() }.getOrNull()
				throw if (locator == ZIP64_LOCATOR_SIGNATURE) Failure.Unsupported("zip64") else Failure.Damaged("inconsistent")
			}
			return Triple(offset.toInt(), directoryEnd.toInt(), entries)
		}
		val startsLikeAZip = archive.size >= 4 && Cursor(archive, 0, 4).u32() == LOCAL_SIGNATURE
		throw if (startsLikeAZip) Failure.Damaged("truncated") else Failure.NotAZip()
	}

	private fun record(directory: Cursor, archive: ByteArray, directoryStart: Int): Record {
		if (directory.u32() != CENTRAL_SIGNATURE) throw Failure.Damaged("inconsistent")
		directory.skip(2)
		val (fields, nameLength, extraLength) = directory.header()
		val commentLength = directory.u16()
		val disk = directory.u16()
		directory.skip(6)
		val localOffset = directory.u32()
		val central = fields.copy(name = directory.bytes(nameLength).toList())
		directory.skip(extraLength + commentLength)

		requireSupported(central, disk, localOffset)
		val name = decodedName(central.name.toByteArray())

		val local = Cursor(archive, localOffset.toInt(), directoryStart)
		if (local.u32() != LOCAL_SIGNATURE) throw Failure.Damaged("inconsistent")
		val (localFields, localNameLength, localExtraLength) = local.header()
		val localHeader = localFields.copy(name = local.bytes(localNameLength).toList())
		local.skip(localExtraLength)
		val dataStart = local.position
		local.skip(central.compressedSize.toInt())
		if (localHeader != central || central.compressedSize != central.size) throw Failure.Damaged("inconsistent")
		return Record(name, central, localOffset.toInt(), dataStart, local.position)
	}

	private fun requireSupported(header: Header, disk: Int, localOffset: Long) {
		if (header.flags and ENCRYPTED_FLAGS != 0) throw Failure.Unsupported("encryption")
		if (header.compressedSize == 0xFFFF_FFFFL || header.size == 0xFFFF_FFFFL || localOffset == 0xFFFF_FFFFL || disk == 0xFFFF) {
			throw Failure.Unsupported("zip64")
		}
		if (disk != 0) throw Failure.Unsupported("multiple disks")
		if (header.flags and DATA_DESCRIPTOR_FLAG != 0) throw Failure.Unsupported("data descriptor")
		if (header.method != 0) throw Failure.Unsupported("compression method ${header.method}")
		val unknownFlags = header.flags and UTF8_FLAG.inv()
		if (unknownFlags != 0) throw Failure.Unsupported("flags $unknownFlags")
	}

	private fun encodedName(name: String): ByteArray {
		if (!isSafe(name)) throw Failure.UnsafeName()
		val bytes = name.encodeToByteArray()
		if (bytes.size > MAXIMUM_NAME) throw Failure.TooLarge()
		return bytes
	}

	private fun decodedName(bytes: ByteArray): String {
		val name = try {
			Charsets.UTF_8.newDecoder()
				.onMalformedInput(CodingErrorAction.REPORT)
				.onUnmappableCharacter(CodingErrorAction.REPORT)
				.decode(ByteBuffer.wrap(bytes))
				.toString()
		} catch (_: CharacterCodingException) {
			throw Failure.UnsafeName()
		}
		if (!isSafe(name)) throw Failure.UnsafeName()
		return name
	}

	private fun isSafe(name: String) = '\u0000' !in name && '\\' !in name &&
		name.split('/').all { it.isNotEmpty() && it != "." && it != ".." }

	private fun crc32(bytes: ByteArray, offset: Int, length: Int) = CRC32().apply { update(bytes, offset, length) }.value

	private fun dosTimestamp(moment: Long): Pair<Int, Int> {
		val utc = LocalDateTime.ofEpochSecond(Math.floorDiv(moment, 1000L).coerceIn(DOS_EARLIEST, DOS_LATEST), 0, ZoneOffset.UTC)
		val date = (utc.year - 1980) shl 9 or (utc.monthValue shl 5) or utc.dayOfMonth
		val time = (utc.hour shl 11) or (utc.minute shl 5) or (utc.second / 2)
		return time to date
	}

	private fun moment(time: Int, date: Int): Long = runCatching {
		LocalDateTime.of(1980 + (date shr 9), date shr 5 and 0x0F, date and 0x1F, time shr 11, time shr 5 and 0x3F, (time and 0x1F) * 2)
			.toEpochSecond(ZoneOffset.UTC) * 1000
	}.getOrDefault(DOS_EARLIEST * 1000)

	private class Cursor(private val bytes: ByteArray, var position: Int, end: Int) {
		private val end = minOf(end, bytes.size)

		fun take(count: Int): Int {
			if (position < 0 || count < 0 || count > end - position) throw Failure.Damaged("out of bounds")
			return position.also { position += count }
		}

		fun skip(count: Int) {
			take(count)
		}

		fun bytes(count: Int): ByteArray = take(count).let { bytes.copyOfRange(it, it + count) }

		fun u16(): Int = ByteBuffer.wrap(bytes, take(2), 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF

		fun u32(): Long = ByteBuffer.wrap(bytes, take(4), 4).order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xFFFF_FFFFL

		fun header(): Triple<Header, Int, Int> {
			skip(2)
			val header = Header(
				flags = u16(),
				method = u16(),
				time = u16(),
				date = u16(),
				crc = u32(),
				compressedSize = u32(),
				size = u32(),
				name = emptyList(),
			)
			return Triple(header, u16(), u16())
		}
	}

	private const val LOCAL_SIGNATURE = 0x04034B50L
	private const val CENTRAL_SIGNATURE = 0x02014B50L
	private const val END_SIGNATURE = 0x06054B50L
	private const val ZIP64_LOCATOR_SIGNATURE = 0x07064B50L
	private const val ENCRYPTED_FLAGS = 0x2041
	private const val DATA_DESCRIPTOR_FLAG = 0x0008
	private const val UTF8_FLAG = 0x0800
	private const val VERSION_NEEDED = 20
	private const val VERSION_MADE_BY_UNIX = 0x0314
	private const val REGULAR_FILE_ATTRIBUTES = 0x81A4 shl 16
	private const val LOCAL_HEADER = 30
	private const val CENTRAL_HEADER = 46
	private const val END_RECORD = 22
	private const val ZIP64_LOCATOR = 20
	private const val MAXIMUM_ENTRIES = 0xFFFF
	private const val MAXIMUM_SIZE = 0xFFFF_FFFFL
	private const val MAXIMUM_NAME = 0xFFFF
	private const val MAXIMUM_COMMENT = 0xFFFF
	private const val DOS_EARLIEST = 315_532_800L
	private const val DOS_LATEST = 4_354_819_198L
}
