package dev.hloth.nativenote.conformance

import org.json.JSONObject

enum class VectorFile {
	Argon2, Hkdf, Export, Markdown,
	Blinding, Content, Note, Frames, Envelope, Padding, Sync, Recovery,
	Mnemonic;

	val fileName get() = "${name.lowercase()}.json"
}

class VectorCase(private val fields: JSONObject) {
	val name: String = fields.getString("name")

	fun has(key: String) = fields.has(key) && !fields.isNull(key)

	fun string(key: String): String = fields.getString(key)

	fun int(key: String): Int = fields.getInt(key)

	fun long(key: String): Long = fields.getLong(key)

	fun bool(key: String): Boolean? = if (has(key)) fields.getBoolean(key) else null

	fun bytes(key: String): ByteArray = string(key).hexToByteArray()

	fun bytesOrNull(key: String): ByteArray? = if (has(key)) bytes(key) else null

	fun objectOf(key: String): JSONObject = fields.getJSONObject(key)

	fun objects(key: String): List<JSONObject> = fields.getJSONArray(key).let { array -> List(array.length()) { array.getJSONObject(it) } }
}

object Vectors {
	fun load(file: VectorFile): List<VectorCase> {
		val cases = JSONObject(VectorFiles.read(file.fileName)).getJSONArray("cases")
		return List(cases.length()) { VectorCase(cases.getJSONObject(it)) }
	}
}
