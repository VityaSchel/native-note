package dev.hloth.nativenote.unlock

import android.system.Os
import dev.hloth.nativenote.crypto.MachineKey
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class LibraryFiles(val directory: File) {
	val database = File(directory, "notes.db")
	val record = UnlockRecordFile.inDirectory(directory)

	val holdsDatabase get() = database.length() > 0

	fun prepareDirectory() {
		if (!directory.isDirectory && !directory.mkdirs()) throw IOException("cannot create ${directory.path}")
	}

	fun setAsideDatabase() {
		if (!database.exists()) return
		val aside = asideName()
		for (suffix in listOf("-wal", "-shm", "")) {
			val file = File(database.path + suffix)
			if (file.exists() && !file.renameTo(File(directory, aside + suffix))) throw IOException("cannot set aside ${file.name}")
		}
	}

	fun erase(): List<String> {
		val failed = mutableListOf<String>()
		runCatching(MachineKey::deleteAll).onFailure { failed += "machine key" }
		runCatching(record::delete).onFailure { failed += UnlockRecordFile.NAME }
		val databases = listOf("", "-wal", "-shm").map { File(database.path + it) } +
			directory.listFiles { file -> file.name.startsWith(SET_ASIDE_PREFIX) }.orEmpty()
		for (file in databases) {
			if (file.exists() && !file.delete()) failed += file.name
		}
		return failed
	}

	private fun asideName(): String {
		val stat = Os.stat(database.path)
		val stamp = SimpleDateFormat("yyyyMMdd'T'HHmmss'Z'", Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }
			.format(Date(stat.st_mtime * 1000))
		return "$SET_ASIDE_PREFIX$stamp-${stat.st_ino}.db"
	}

	companion object {
		const val SET_ASIDE_PREFIX = "notes-set-aside-"
	}
}
