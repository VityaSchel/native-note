package dev.hloth.nativenote.export

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.IOException

class PickedDocument(private val resolver: ContentResolver, private val uri: Uri) {
	fun write(bytes: ByteArray) {
		val stream = resolver.openOutputStream(uri, "wt") ?: throw IOException("the file could not be opened for writing")
		try {
			stream.use { it.write(bytes) }
		} catch (error: IOException) {
			runCatching { delete() }
			throw error
		}
	}

	fun deleteIfEmpty() {
		if (open().use { it.read() } < 0) delete()
	}

	fun read(): ByteArray = open().use { it.readBytes() }

	fun head(): ByteArray = open().use { stream ->
		val head = ByteArray(HEAD_LENGTH)
		var length = 0
		while (length < head.size) {
			val read = stream.read(head, length, head.size - length)
			if (read < 0) break
			length += read
		}
		head.copyOf(length)
	}

	fun size(): Long =
		resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null }
			?: resolver.openFileDescriptor(uri, "r")?.use { it.statSize }?.takeIf { it >= 0 }
			?: throw IOException("the file's size is unknown")

	private fun open() = resolver.openInputStream(uri) ?: throw IOException("the file could not be opened")

	private fun delete() = DocumentsContract.deleteDocument(resolver, uri)

	private companion object {
		const val HEAD_LENGTH = 64
	}
}
