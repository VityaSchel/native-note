package dev.hloth.nativenote.sync

import java.io.ByteArrayOutputStream
import java.util.UUID

enum class WireError { Truncated, TrailingBytes, UnknownDiscriminant, NotCanonical }

class WireException(val error: WireError) : Exception(error.name)

class WireReader(private val buffer: ByteArray) {
	private var offset = 0

	private val remaining get() = buffer.size - offset

	fun take(count: Long): ByteArray {
		if (count > remaining) throw WireException(WireError.Truncated)
		return buffer.copyOfRange(offset, offset + count.toInt()).also { offset += count.toInt() }
	}

	fun u8(): Int = take(1)[0].toInt() and 0xff

	fun u32(): UInt = take(4).fold(0u) { value, byte -> value shl 8 or byte.toUByte().toUInt() }

	fun u64(): ULong = take(8).fold(0uL) { value, byte -> value shl 8 or byte.toUByte().toULong() }

	fun i64(): Long = u64().toLong()

	fun uuid(): UUID = uuidOf(take(16))

	fun bool(): Boolean = when (u8()) {
		0 -> false
		1 -> true
		else -> throw WireException(WireError.NotCanonical)
	}

	fun bytes(): ByteArray = take(u32().toLong())

	fun <T> items(item: (WireReader) -> T): List<T> {
		val count = u32()
		return buildList { for (index in 0u until count) add(item(this@WireReader)) }
	}

	fun finish() {
		if (remaining != 0) throw WireException(WireError.TrailingBytes)
	}

	fun finishFilled(block: Int) {
		if ((offset until buffer.size).any { buffer[it] != 0.toByte() }) throw WireException(WireError.TrailingBytes)
		if (buffer.size % block != 0 || remaining >= block) throw WireException(WireError.NotCanonical)
	}
}

class WireWriter {
	private val output = ByteArrayOutputStream()

	val bytes: ByteArray get() = output.toByteArray()

	fun u8(value: Int) = output.write(value)

	fun u32(value: UInt) = repeat(4) { output.write((value shr (24 - 8 * it)).toInt()) }

	fun u64(value: ULong) = repeat(8) { output.write((value shr (56 - 8 * it)).toInt()) }

	fun i64(value: Long) = u64(value.toULong())

	fun fixed(value: ByteArray) = output.write(value)

	fun bytes(value: ByteArray) {
		u32(value.size.toUInt())
		fixed(value)
	}
}

fun UUID.bytes(): ByteArray {
	val writer = WireWriter()
	writer.i64(mostSignificantBits)
	writer.i64(leastSignificantBits)
	return writer.bytes
}

fun uuidOf(bytes: ByteArray): UUID {
	val reader = WireReader(bytes)
	return UUID(reader.i64(), reader.i64())
}
