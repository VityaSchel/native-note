package dev.hloth.nativenote.storage

class SQLiteStatement internal constructor(private var handle: Long) : AutoCloseable {
	fun bind(index: Int, value: Long?) {
		if (value == null) nativeBindNull(openHandle(), index) else nativeBindLong(openHandle(), index, value)
	}

	fun bind(index: Int, value: String?) {
		if (value == null) nativeBindNull(openHandle(), index) else nativeBindText(openHandle(), index, value.encodeToByteArray())
	}

	fun bind(index: Int, value: ByteArray?) {
		if (value == null) nativeBindNull(openHandle(), index) else nativeBindBlob(openHandle(), index, value)
	}

	fun step(): Boolean = nativeStep(openHandle())

	fun isNull(column: Int) = nativeColumnType(openHandle(), column) == NULL_TYPE

	fun long(column: Int): Long = nativeColumnLong(openHandle(), column)

	fun string(column: Int): String = nativeColumnText(openHandle(), column).decodeToString()

	fun bytes(column: Int): ByteArray = nativeColumnBlob(openHandle(), column)

	fun reset() = nativeReset(openHandle())

	override fun close() {
		if (handle != 0L) nativeFinalize(handle)
		handle = 0
	}

	private fun openHandle(): Long {
		check(handle != 0L) { "the statement is finalized" }
		return handle
	}

	private companion object {
		const val NULL_TYPE = 5

		@JvmStatic
		external fun nativeBindNull(handle: Long, index: Int)

		@JvmStatic
		external fun nativeBindLong(handle: Long, index: Int, value: Long)

		@JvmStatic
		external fun nativeBindText(handle: Long, index: Int, utf8: ByteArray)

		@JvmStatic
		external fun nativeBindBlob(handle: Long, index: Int, value: ByteArray)

		@JvmStatic
		external fun nativeStep(handle: Long): Boolean

		@JvmStatic
		external fun nativeColumnType(handle: Long, column: Int): Int

		@JvmStatic
		external fun nativeColumnLong(handle: Long, column: Int): Long

		@JvmStatic
		external fun nativeColumnText(handle: Long, column: Int): ByteArray

		@JvmStatic
		external fun nativeColumnBlob(handle: Long, column: Int): ByteArray

		@JvmStatic
		external fun nativeReset(handle: Long)

		@JvmStatic
		external fun nativeFinalize(handle: Long)
	}
}
