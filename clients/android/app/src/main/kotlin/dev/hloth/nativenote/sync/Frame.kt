package dev.hloth.nativenote.sync

class Write(val blindedId: ByteArray, val v: UInt, val writeId: ByteArray, val payload: ByteArray) {
	val encodedLength get() = HEADER_LENGTH + payload.size

	fun encode(writer: WireWriter) {
		writer.fixed(blindedId)
		writer.u32(v)
		writer.fixed(writeId)
		writer.bytes(payload)
	}

	override fun equals(other: Any?) = other is Write && blindedId.contentEquals(other.blindedId) && v == other.v &&
		writeId.contentEquals(other.writeId) && payload.contentEquals(other.payload)

	override fun hashCode() = listOf(blindedId.contentHashCode(), v, writeId.contentHashCode(), payload.contentHashCode()).hashCode()

	override fun toString() = "Write(v=$v, ${payload.size} payload bytes)"

	companion object {
		const val ID_LENGTH = 16
		private const val HEADER_LENGTH = ID_LENGTH + 4 + ID_LENGTH + 4

		fun decode(reader: WireReader) = Write(reader.take(ID_LENGTH.toLong()), reader.u32(), reader.take(ID_LENGTH.toLong()), reader.bytes())
	}
}

enum class Status(val byte: Int) {
	Accepted(0x01),
	Conflict(0x02),
	TooLarge(0x03),
}

data class WriteResult(val status: Status, val v: UInt)

enum class ErrorReason(val byte: Int) {
	Malformed(0x01),
	Unsupported(0x02),
	Fault(0x03),
}

sealed interface Request {
	data class Sync(val since: ULong, val writes: List<Write>) : Request

	data object Get : Request

	class Put(val v: UInt, val blob: ByteArray) : Request {
		override fun equals(other: Any?) = other is Put && v == other.v && blob.contentEquals(other.blob)

		override fun hashCode() = 31 * v.hashCode() + blob.contentHashCode()
	}

	fun encoded(): ByteArray {
		val writer = WireWriter()
		when (this) {
			is Sync -> {
				writer.u8(Action.SYNC)
				writer.u64(since)
				writer.u32(writes.size.toUInt())
				writes.forEach { it.encode(writer) }
			}
			Get -> writer.u8(Action.GET)
			is Put -> {
				writer.u8(Action.PUT)
				writer.u32(v)
				writer.bytes(blob)
			}
		}
		return writer.bytes
	}

	companion object {
		const val SYNC_HEADER_LENGTH = 1 + 8 + 4
	}
}

sealed interface Response {
	data class Sync(val results: List<WriteResult>, val changes: List<Write>, val nextSeq: ULong, val more: Boolean) : Response

	class Get(val v: UInt, val blob: ByteArray) : Response {
		override fun equals(other: Any?) = other is Get && v == other.v && blob.contentEquals(other.blob)

		override fun hashCode() = 31 * v.hashCode() + blob.contentHashCode()
	}

	data class Put(val status: Status, val v: UInt) : Response

	data class Error(val reason: ErrorReason) : Response

	companion object {
		fun decode(bytes: ByteArray): Response {
			val reader = WireReader(bytes)
			val response = when (reader.u8()) {
				Action.SYNC -> Sync(
					results = reader.items { WriteResult(status(it), it.u32()) },
					changes = reader.items(Write::decode),
					nextSeq = reader.u64(),
					more = reader.bool(),
				)
				Action.GET -> Get(reader.u32(), reader.bytes())
				Action.PUT -> {
					val status = status(reader)
					if (status == Status.TooLarge) throw WireException(WireError.UnknownDiscriminant)
					Put(status, reader.u32())
				}
				Action.ERROR -> {
					val byte = reader.u8()
					Error(ErrorReason.entries.firstOrNull { it.byte == byte } ?: ErrorReason.Fault)
				}
				else -> throw WireException(WireError.UnknownDiscriminant)
			}
			reader.finish()
			return response
		}

		private fun status(reader: WireReader): Status {
			val byte = reader.u8()
			return Status.entries.firstOrNull { it.byte == byte } ?: throw WireException(WireError.UnknownDiscriminant)
		}
	}
}

private object Action {
	const val SYNC = 0x01
	const val GET = 0x02
	const val PUT = 0x03
	const val ERROR = 0xff
}
