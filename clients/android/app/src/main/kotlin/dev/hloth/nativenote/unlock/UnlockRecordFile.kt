package dev.hloth.nativenote.unlock

import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.util.UUID

class UnlockRecordFile(val file: File) {
	fun read(): UnlockRecord? = if (file.exists()) UnlockRecord.decode(file.readBytes()) else null

	fun write(record: UnlockRecord) = durablyReplace(file, record.encoded())

	fun delete() {
		if (file.exists() && !file.delete()) throw IOException("cannot delete ${file.name}")
	}

	companion object {
		const val NAME = "unlock-record"

		fun inDirectory(directory: File) = UnlockRecordFile(File(directory, NAME))

		fun durablyReplace(target: File, bytes: ByteArray) {
			val directory = target.parentFile ?: throw IOException("${target.path} has no directory")
			if (!directory.isDirectory && !directory.mkdirs()) throw IOException("cannot create ${directory.path}")
			val temporary = File(directory, ".${target.name}.${UUID.randomUUID()}")
			val descriptor = Os.open(temporary.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_CLOEXEC, 0b110_000_000)
			try {
				var written = 0
				while (written < bytes.size) written += Os.write(descriptor, bytes, written, bytes.size - written)
				Os.fsync(descriptor)
			} catch (failure: Exception) {
				temporary.delete()
				throw failure
			} finally {
				Os.close(descriptor)
			}
			try {
				Os.rename(temporary.path, target.path)
			} catch (failure: Exception) {
				temporary.delete()
				throw failure
			}
			val folder = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC, 0)
			try {
				Os.fsync(folder)
			} finally {
				Os.close(folder)
			}
		}
	}
}
