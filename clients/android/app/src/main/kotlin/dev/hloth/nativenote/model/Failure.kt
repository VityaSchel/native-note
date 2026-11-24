package dev.hloth.nativenote.model

import androidx.annotation.StringRes
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.MachineKey
import dev.hloth.nativenote.export.ExportEnvelope
import dev.hloth.nativenote.export.LibraryArchive
import dev.hloth.nativenote.export.NoteMarkdown
import dev.hloth.nativenote.export.ZipArchive
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.SQLiteException
import dev.hloth.nativenote.storage.Schema
import dev.hloth.nativenote.unlock.Unlock
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockRecord
import java.io.IOException

class TooLargeForDevice : Exception("the file needs more memory than this device gives the app")

sealed interface Failure {
	data object WrongPassword : Failure

	data object WrongExportPassphrase : Failure

	data class Unexpected(@StringRes val reason: Int, val detail: String? = null, @StringRes val title: Int = R.string.failure_title) : Failure

	data class Unsaved(val reason: Unexpected) : Failure

	companion object {
		fun of(error: Throwable, @StringRes title: Int): Failure = when (val failure = of(error)) {
			is Unexpected -> failure.copy(title = title)
			else -> failure
		}

		fun reason(error: Throwable): Unexpected = of(error) as? Unexpected ?: Unexpected(R.string.failure_unexpected, error.toString())

		fun of(error: Throwable): Failure = when (error) {
			is UnlockKeys.WrongPassword -> WrongPassword
			is Unlock.Failure.NeverSetUp -> Unexpected(R.string.failure_never_set_up)
			is Unlock.Failure.AlreadySetUp -> Unexpected(R.string.failure_already_set_up)
			is Unlock.Failure.DatabaseMissing -> Unexpected(R.string.failure_database_missing)
			is Unlock.Failure.KeyRejected -> Unexpected(R.string.failure_key_rejected)
			is UnlockKeys.RecordNotProven -> Unexpected(R.string.failure_password_not_changed)
			is MachineKey.BoundToAnotherDevice -> Unexpected(R.string.failure_bound_to_another_device)
			is UnlockRecord.Unreadable -> Unexpected(if (error.isNewerVersion) R.string.failure_record_newer else R.string.failure_record_damaged)
			is Schema.NewerSchema -> Unexpected(R.string.failure_schema_newer)
			is SQLiteException -> Unexpected(R.string.failure_database, error.message)
			is SQLiteConnection.Closed -> Unexpected(R.string.failure_database_closed)
			is ExportEnvelope.Failure.WrongPassphraseOrDamaged -> WrongExportPassphrase
			is ExportEnvelope.Failure.NewerVersion -> Unexpected(R.string.failure_export_newer)
			is ExportEnvelope.Failure.ParametersOutOfBounds -> Unexpected(R.string.failure_export_parameters)
			is ZipArchive.Failure.TooLarge -> Unexpected(R.string.failure_export_too_large)
			is LibraryArchive.Failure.TooLarge -> Unexpected(R.string.failure_import_too_large)
			is TooLargeForDevice -> Unexpected(R.string.failure_too_large_for_device)
			is ExportEnvelope.Failure, is ZipArchive.Failure, is NoteMarkdown.Failure, is LibraryArchive.Failure -> Unexpected(R.string.failure_not_an_export)
			is IOException -> Unexpected(R.string.failure_file, error.message)
			else -> Unexpected(R.string.failure_unexpected, error.toString())
		}
	}
}
