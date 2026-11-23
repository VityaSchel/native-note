package dev.hloth.nativenote.sync

import java.nio.charset.CharacterCodingException
import java.util.UUID

sealed interface Content {
	val id: UUID

	class Note(
		override val id: UUID,
		val createdAt: Long,
		val updatedAt: Long,
		val body: String,
		val ext: ByteArray = ByteArray(0),
	) : Content {
		override fun equals(other: Any?) = other is Note && id == other.id && createdAt == other.createdAt &&
			updatedAt == other.updatedAt && body == other.body && ext.contentEquals(other.ext)

		override fun hashCode() = listOf(id, createdAt, updatedAt, body, ext.contentHashCode()).hashCode()

		override fun toString() = "Note($id, $createdAt, $updatedAt, ${body.length} chars, ${ext.size} ext bytes)"
	}

	data class Tombstone(override val id: UUID, val deletedAt: Long) : Content

	data class Prefix(val version: Int, val kind: Int, val id: UUID) {
		val isKnown get() = version == VERSION && kind in setOf(NOTE_KIND, TOMBSTONE_KIND)
	}

	fun encoded(): ByteArray {
		val writer = WireWriter()
		writer.u8(VERSION)
		when (this) {
			is Note -> {
				writer.u8(NOTE_KIND)
				writer.fixed(id.bytes())
				writer.i64(createdAt)
				writer.i64(updatedAt)
				writer.bytes(body.encodeToByteArray())
				writer.bytes(ext)
			}
			is Tombstone -> {
				writer.u8(TOMBSTONE_KIND)
				writer.fixed(id.bytes())
				writer.i64(deletedAt)
			}
		}
		val fields = writer.bytes
		return fields.copyOf(fields.size + (BLOCK - fields.size % BLOCK) % BLOCK)
	}

	companion object {
		const val BLOCK = 4096
		private const val VERSION = 0x01
		private const val NOTE_KIND = 0x01
		private const val TOMBSTONE_KIND = 0x02

		fun prefix(bytes: ByteArray): Prefix {
			val reader = WireReader(bytes)
			return Prefix(reader.u8(), reader.u8(), reader.uuid())
		}

		fun decode(bytes: ByteArray): Content {
			val reader = WireReader(bytes)
			if (reader.u8() != VERSION) throw WireException(WireError.UnknownDiscriminant)
			val content = when (reader.u8()) {
				NOTE_KIND -> Note(
					id = reader.uuid(),
					createdAt = reader.i64(),
					updatedAt = reader.i64(),
					body = utf8(reader.bytes()),
					ext = reader.bytes(),
				)
				TOMBSTONE_KIND -> Tombstone(reader.uuid(), reader.i64())
				else -> throw WireException(WireError.UnknownDiscriminant)
			}
			reader.finishFilled(BLOCK)
			return content
		}

		private fun utf8(bytes: ByteArray): String = try {
			bytes.decodeToString(throwOnInvalidSequence = true)
		} catch (_: CharacterCodingException) {
			throw WireException(WireError.NotCanonical)
		}
	}
}
