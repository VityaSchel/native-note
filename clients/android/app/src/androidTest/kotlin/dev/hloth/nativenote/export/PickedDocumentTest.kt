package dev.hloth.nativenote.export

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.hloth.nativenote.export.PickedDocument
import java.io.File
import java.io.IOException
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PickedDocumentTest {
	private class OneFile(val file: File, val refusesWrites: Boolean) : ContentProvider() {
		override fun onCreate() = true

		override fun call(authority: String, method: String, arg: String?, extras: Bundle?): Bundle? {
			check(file.delete())
			return Bundle()
		}

		override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
			if (mode.startsWith("w") && refusesWrites) {
				file.writeBytes(ByteArray(10))
				return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
			}
			return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
		}

		override fun getType(uri: Uri) = null

		override fun query(uri: Uri, projection: Array<String>?, selection: String?, arguments: Array<String>?, order: String?): Cursor? = null

		override fun insert(uri: Uri, values: ContentValues?) = null

		override fun delete(uri: Uri, selection: String?, arguments: Array<String>?) = 0

		override fun update(uri: Uri, values: ContentValues?, selection: String?, arguments: Array<String>?) = 0
	}

	@get:Rule
	val folder = TemporaryFolder()

	private val file by lazy { File(folder.root, "export.zip").apply { createNewFile() } }

	private fun document(refusesWrites: Boolean = false) =
		PickedDocument(ContentResolver.wrap(OneFile(file, refusesWrites)), DocumentsContract.buildDocumentUri("test", "export"))

	@Test
	fun aDocumentIsWrittenReadAndMeasured() {
		val bytes = ByteArray(1_000) { it.toByte() }
		document().write(bytes)

		assertArrayEquals(bytes, document().read())
		assertArrayEquals(bytes.copyOf(64), document().head())
		assertEquals(1_000, document().size())
	}

	@Test
	fun aWriteThatFailsPartwayLeavesNoCutOffFile() {
		val failure = runCatching { document(refusesWrites = true).write(ByteArray(1 shl 20)) }.exceptionOrNull()

		assertTrue("$failure", failure is IOException)
		assertFalse(file.exists())
	}

	@Test
	fun onlyAnEmptyDocumentIsDeletedAfterARefusedExport() {
		file.writeText("someone's file")
		document().deleteIfEmpty()
		assertEquals("someone's file", file.readText())

		file.writeText("")
		document().deleteIfEmpty()
		assertFalse(file.exists())
	}
}
