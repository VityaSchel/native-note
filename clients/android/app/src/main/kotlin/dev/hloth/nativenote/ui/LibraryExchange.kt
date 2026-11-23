package dev.hloth.nativenote.ui

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.ImportSummary
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun LibraryExchange(model: AppModel) {
	val context = LocalContext.current
	val resources = LocalResources.current
	val scope = rememberCoroutineScope()
	var exporting by remember { mutableStateOf(false) }
	var encryptedImport by remember { mutableStateOf<Uri?>(null) }
	var summary by remember { mutableStateOf<ImportSummary?>(null) }

	val export = { uri: Uri? -> model.exportLibrary(uri?.let { { bytes: ByteArray -> write(context.contentResolver, it, bytes) } }) }
	val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(EXPORT_TYPE)) { export(it) }
	val saveEncrypted = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(ENCRYPTED_EXPORT_TYPE)) { export(it) }
	val runImport = { uri: Uri, passphrase: String? ->
		scope.launch {
			val imported = model.importLibrary(passphrase, { sizeOf(context.contentResolver, uri) }) { read(context.contentResolver, uri) }.await()
			if (imported != null) {
				summary = imported
				encryptedImport = null
			} else if (model.failure != Failure.WrongExportPassphrase) {
				encryptedImport = null
			}
		}
	}
	val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
		model.pickerClosed()
		if (uri == null) return@rememberLauncherForActivityResult
		scope.launch {
			val head = withContext(Dispatchers.IO) { runCatching { readHead(context.contentResolver, uri) }.getOrDefault(ByteArray(0)) }
			if (model.isEncryptedExport(head)) encryptedImport = uri else runImport(uri, null)
		}
	}

	SettingsSection(stringResource(R.string.settings_notes), listOf(
		SettingsRow(stringResource(R.string.export_notes), stringResource(R.string.export_notes_explanation), onClick = { exporting = true }),
		SettingsRow(stringResource(R.string.import_notes), stringResource(R.string.import_notes_explanation), enabled = !model.isImporting, onClick = {
			model.prepareImport()
			open.launch(arrayOf("*/*"))
		}),
	))

	if (exporting) {
		ExportDialog(onDismiss = { exporting = false }) { passphrase ->
			exporting = false
			model.prepareExport(passphrase)
			if (passphrase == null) save.launch(resources.getString(R.string.export_file_name)) else saveEncrypted.launch(resources.getString(R.string.encrypted_export_file_name))
		}
	}
	encryptedImport?.let { uri ->
		ImportPassphraseDialog(
			working = model.isImporting,
			wrong = model.failure == Failure.WrongExportPassphrase,
			onDismiss = {
				encryptedImport = null
				if (model.failure == Failure.WrongExportPassphrase) model.dismissFailure()
			},
			onImport = { passphrase ->
				if (model.failure == Failure.WrongExportPassphrase) model.dismissFailure()
				runImport(uri, passphrase)
			},
		)
	}
	summary?.let {
		AlertDialog(
			onDismissRequest = { summary = null },
			text = { Text(summaryMessage(it)) },
			confirmButton = { TextButton(onClick = { summary = null }) { Text(stringResource(R.string.ok)) } },
		)
	}
}

@Composable
private fun ExportDialog(onDismiss: () -> Unit, onExport: (String?) -> Unit) {
	var encrypt by remember { mutableStateOf(false) }
	val passphrase = remember { TextFieldState() }
	val verify = remember { TextFieldState() }
	var mismatched by remember { mutableStateOf(false) }
	val canExport = !encrypt || passphrase.text.isNotEmpty()
	val submit = submit@{
		if (!canExport) return@submit
		mismatched = encrypt && passphrase.text.toString() != verify.text.toString()
		if (!mismatched) onExport(if (encrypt) passphrase.text.toString() else null)
	}
	AlertDialog(
		onDismissRequest = onDismiss,
		title = { Text(stringResource(R.string.export_title)) },
		text = {
			Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(stringResource(R.string.export_explanation))
				Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
					Text(stringResource(R.string.encrypt_with_passphrase), Modifier.weight(1f))
					Switch(checked = encrypt, onCheckedChange = { encrypt = it })
				}
				if (encrypt) {
					PasswordField(passphrase, stringResource(R.string.passphrase), imeAction = ImeAction.Next)
					PasswordField(
						verify,
						stringResource(R.string.verify_passphrase),
						error = if (mismatched) stringResource(R.string.passphrases_mismatch) else null,
						onAction = submit,
					)
				}
			}
		},
		confirmButton = { TextButton(onClick = submit, enabled = canExport) { Text(stringResource(R.string.export_action)) } },
		dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
	)
}

@Composable
private fun ImportPassphraseDialog(working: Boolean, wrong: Boolean, onDismiss: () -> Unit, onImport: (String) -> Unit) {
	val passphrase = remember { TextFieldState() }
	val submit = { if (passphrase.text.isNotEmpty() && !working) onImport(passphrase.text.toString()) }
	AlertDialog(
		onDismissRequest = { if (!working) onDismiss() },
		title = { Text(stringResource(R.string.import_passphrase_title)) },
		text = {
			Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
				Text(stringResource(R.string.import_passphrase_message))
				PasswordField(
					passphrase,
					stringResource(R.string.passphrase),
					enabled = !working,
					error = if (wrong) stringResource(R.string.wrong_export_passphrase) else null,
					onAction = submit,
				)
			}
		},
		confirmButton = {
			TextButton(onClick = submit, enabled = passphrase.text.isNotEmpty() && !working) { BusyLabel(stringResource(R.string.import_action), working) }
		},
		dismissButton = { TextButton(onClick = onDismiss, enabled = !working) { Text(stringResource(R.string.cancel)) } },
	)
}

@Composable
private fun summaryMessage(summary: ImportSummary): String {
	val resources = LocalResources.current
	val imported = resources.getQuantityString(R.plurals.imported_notes, summary.added, summary.added)
	val details = listOfNotNull(
		if (summary.skipped > 0) resources.getQuantityString(R.plurals.imported_skipped, summary.skipped, summary.skipped) else null,
		if (summary.notImported > 0) resources.getQuantityString(R.plurals.imported_not_imported, summary.notImported, summary.notImported) else null,
	)
	return if (details.isEmpty()) imported else "$imported ${details.joinToString(", ")}."
}

private fun write(resolver: ContentResolver, uri: Uri, bytes: ByteArray) {
	(resolver.openOutputStream(uri, "wt") ?: throw IOException("the file could not be opened for writing")).use { it.write(bytes) }
}

private fun read(resolver: ContentResolver, uri: Uri): ByteArray =
	(resolver.openInputStream(uri) ?: throw IOException("the file could not be opened")).use { it.readBytes() }

private fun readHead(resolver: ContentResolver, uri: Uri): ByteArray =
	(resolver.openInputStream(uri) ?: throw IOException("the file could not be opened")).use { stream ->
		val head = ByteArray(HEAD_LENGTH)
		var length = 0
		while (length < head.size) {
			val read = stream.read(head, length, head.size - length)
			if (read < 0) break
			length += read
		}
		head.copyOf(length)
	}

private fun sizeOf(resolver: ContentResolver, uri: Uri): Long =
	resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null }
		?: resolver.openFileDescriptor(uri, "r")?.use { it.statSize }?.takeIf { it >= 0 }
		?: throw IOException("the file's size is unknown")

private const val EXPORT_TYPE = "application/zip"
private const val ENCRYPTED_EXPORT_TYPE = "application/octet-stream"
private const val HEAD_LENGTH = 64
