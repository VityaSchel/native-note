package dev.hloth.nativenote.storage

import java.io.File

class SQLiteConnection(file: File, rawKey: ByteArray, create: Boolean = true) : AutoCloseable {
	private var handle = nativeOpen(file.path.encodeToByteArray(), create)

	init {
		try {
			execute("PRAGMA busy_timeout = $BUSY_TIMEOUT_MILLISECONDS")
			nativeKey(handle, rawKey)
			scalar("SELECT count(*) FROM sqlite_schema")
			execute("PRAGMA journal_mode = WAL")
			execute("PRAGMA synchronous = FULL")
			execute("PRAGMA foreign_keys = ON")
		} catch (failure: Throwable) {
			close()
			throw failure
		}
	}

	fun execute(sql: String) = nativeExec(openHandle(), sql.encodeToByteArray())

	fun prepare(sql: String) = SQLiteStatement(nativePrepare(openHandle(), sql.encodeToByteArray()))

	fun scalar(sql: String): String? = prepare(sql).use { if (it.step()) it.string(0) else null }

	fun <T> transaction(body: () -> T): T {
		execute("BEGIN IMMEDIATE")
		try {
			return body().also { execute("COMMIT") }
		} catch (failure: Throwable) {
			runCatching { execute("ROLLBACK") }
			throw failure
		}
	}

	override fun close() {
		if (handle != 0L) nativeClose(handle)
		handle = 0
	}

	private fun openHandle(): Long {
		if (handle == 0L) throw Closed()
		return handle
	}

	class Closed : IllegalStateException("the connection is closed")

	companion object {
		const val BUSY_TIMEOUT_MILLISECONDS = 5_000

		init {
			System.loadLibrary("sqlcipher")
		}

		@JvmStatic
		private external fun nativeOpen(path: ByteArray, create: Boolean): Long

		@JvmStatic
		private external fun nativeKey(handle: Long, rawKey: ByteArray)

		@JvmStatic
		private external fun nativeExec(handle: Long, sql: ByteArray)

		@JvmStatic
		private external fun nativePrepare(handle: Long, sql: ByteArray): Long

		@JvmStatic
		private external fun nativeClose(handle: Long)
	}
}
