package dev.hloth.nativenote.unlock

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.MachineKey
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.SQLiteException
import dev.hloth.nativenote.storage.Schema

object Unlock {
	sealed class Failure(message: String) : Exception(message) {
		class NeverSetUp : Failure("no unlock record")

		class AlreadySetUp : Failure("already set up")

		class DatabaseMissing : Failure("the notes database is missing")

		class KeyRejected : Failure("the notes database does not open with its unlock record")

		class PasswordNotChanged : Failure("the new unlock record did not land")
	}

	class Unlocked(val connection: SQLiteConnection, val record: UnlockRecord)

	private const val WRONG_KEY = 26

	fun setUp(password: String, files: LibraryFiles, makeParameters: () -> UnlockParameters): Unlocked {
		if (files.record.read() != null) throw Failure.AlreadySetUp()
		files.prepareDirectory()
		files.setAsideDatabase()
		MachineKey.deleteAll()
		val key = AesGcm.randomBytes(32)
		try {
			val record = UnlockKeys.makeRecord(password, key, makeParameters())
			val connection = SQLiteConnection(files.database, key, create = true)
			try {
				Schema.prepare(connection)
				files.record.write(record)
			} catch (failure: Throwable) {
				connection.close()
				throw failure
			}
			return Unlocked(connection, record)
		} finally {
			key.fill(0)
		}
	}

	fun open(password: String, files: LibraryFiles): Unlocked {
		val record = files.record.read() ?: throw Failure.NeverSetUp()
		if (!files.holdsDatabase) throw Failure.DatabaseMissing()
		val key = UnlockKeys.databaseKey(password, record)
		try {
			return Unlocked(openDatabase(files, key), record)
		} finally {
			key.fill(0)
		}
	}

	fun open(databaseKey: ByteArray, files: LibraryFiles): Unlocked {
		val record = files.record.read() ?: throw Failure.NeverSetUp()
		if (!files.holdsDatabase) throw Failure.DatabaseMissing()
		return Unlocked(openDatabase(files, databaseKey), record)
	}

	fun provenKey(password: String, record: UnlockRecord, files: LibraryFiles): ByteArray {
		val key = UnlockKeys.databaseKey(password, record)
		try {
			openDatabase(files, key).close()
			return key
		} catch (failure: Throwable) {
			key.fill(0)
			throw failure
		}
	}

	fun changePassword(
		current: String,
		new: String,
		record: UnlockRecord,
		files: LibraryFiles,
		calibrate: () -> Argon2.Parameters,
		beforeReplacing: () -> Unit,
	): UnlockRecord {
		val key = UnlockKeys.databaseKey(current, record)
		try {
			openDatabase(files, key).close()
			val calibrated = calibrate()
			val argon = if (calibrated.m > record.parameters.argon.m) calibrated else record.parameters.argon
			val parameters = UnlockParameters(AesGcm.randomBytes(UnlockParameters.SALT_LENGTH), argon, record.parameters.machineKeyId)
			val changed = UnlockKeys.makeRecord(new, key, parameters)
			beforeReplacing()
			files.record.write(changed)
			return changed
		} finally {
			key.fill(0)
		}
	}

	private fun openDatabase(files: LibraryFiles, key: ByteArray): SQLiteConnection {
		val connection = try {
			SQLiteConnection(files.database, key, create = false)
		} catch (failure: SQLiteException) {
			if (failure.code == WRONG_KEY) throw Failure.KeyRejected()
			throw failure
		}
		try {
			Schema.prepare(connection)
		} catch (failure: Throwable) {
			connection.close()
			throw failure
		}
		return connection
	}
}
