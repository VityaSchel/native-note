package dev.hloth.nativenote.sync

object Padding {
	const val BODY_MAX = 2 shl 20
	private const val LENGTH_PREFIX = 4
	private const val SMALLEST = 256
	const val INNER_MAX = BODY_MAX - LENGTH_PREFIX

	private fun bucket(holding: Long): Int? {
		var bucket = SMALLEST.toLong()
		while (bucket < holding) bucket *= 2
		return if (bucket <= BODY_MAX) bucket.toInt() else null
	}

	fun pad(inner: ByteArray): ByteArray? {
		val bucket = bucket(LENGTH_PREFIX.toLong() + inner.size) ?: return null
		val writer = WireWriter()
		writer.bytes(inner)
		return writer.bytes.copyOf(bucket)
	}

	fun unpad(padded: ByteArray): ByteArray? {
		val inner = runCatching { WireReader(padded).bytes() }.getOrNull() ?: return null
		val end = LENGTH_PREFIX + inner.size
		if (bucket(end.toLong()) != padded.size) return null
		if ((end until padded.size).any { padded[it] != 0.toByte() }) return null
		return inner
	}
}
