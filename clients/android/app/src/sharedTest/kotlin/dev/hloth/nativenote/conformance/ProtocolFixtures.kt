package dev.hloth.nativenote.conformance

import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.ErrorReason
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.Response
import dev.hloth.nativenote.sync.WireError
import dev.hloth.nativenote.sync.WireReader
import dev.hloth.nativenote.sync.WireWriter
import dev.hloth.nativenote.sync.Write
import dev.hloth.nativenote.sync.uuidOf
import org.json.JSONObject

fun content(fields: JSONObject): Content {
	val id = uuidOf(fields.getString("uuid").hexToByteArray())
	return when (fields.getString("kind")) {
		"note" -> Content.Note(
			id = id,
			createdAt = fields.getLong("createdAt"),
			updatedAt = fields.getLong("updatedAt"),
			body = fields.getString("body"),
			ext = fields.getString("ext").hexToByteArray(),
		)
		"tombstone" -> Content.Tombstone(id, fields.getLong("deletedAt"))
		else -> error("unknown kind ${fields.getString("kind")}")
	}
}

fun wireError(name: String) = WireError.valueOf(name)

fun errorReason(name: String) = ErrorReason.entries.single { it.name.lowercase() == name }

object RequestDecoding {
	fun decode(bytes: ByteArray): Request {
		val reader = WireReader(bytes)
		val request = when (reader.u8()) {
			0x01 -> Request.Sync(reader.u64(), reader.items(Write::decode))
			0x02 -> Request.Get
			0x03 -> Request.Put(reader.u32(), reader.bytes())
			else -> error("unknown action")
		}
		reader.finish()
		return request
	}
}

fun responseBytes(response: Response): ByteArray {
	val writer = WireWriter()
	when (response) {
		is Response.Sync -> {
			writer.u8(0x01)
			writer.u32(response.results.size.toUInt())
			response.results.forEach {
				writer.u8(it.status.byte)
				writer.u32(it.v)
			}
			writer.u32(response.changes.size.toUInt())
			response.changes.forEach { it.encode(writer) }
			writer.u64(response.nextSeq)
			writer.u8(if (response.more) 1 else 0)
		}
		is Response.Get -> {
			writer.u8(0x02)
			writer.u32(response.v)
			writer.bytes(response.blob)
		}
		is Response.Put -> {
			writer.u8(0x03)
			writer.u8(response.status.byte)
			writer.u32(response.v)
		}
		is Response.Error -> {
			writer.u8(0xff)
			writer.u8(response.reason.byte)
		}
	}
	return writer.bytes
}
