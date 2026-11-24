package dev.hloth.nativenote.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.hloth.nativenote.R
import dev.hloth.nativenote.export.PickedDocument
import dev.hloth.nativenote.model.AppModel
import dev.hloth.nativenote.model.Failure
import dev.hloth.nativenote.model.ImportSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class LibraryPickers(val export: () -> Unit, val import: () -> Unit)

@Composable
fun rememberLibraryPickers(model: AppModel): LibraryPickers {
	val context = LocalContext.current
	val resources = LocalResources.current
	val scope = rememberCoroutineScope()
	var exporting by remember { mutableStateOf(false) }
	var encryptedImport by remember { mutableStateOf<PickedDocument?>(null) }
	val unlocked = model.phase == AppModel.Phase.Unlocked
	LaunchedEffect(unlocked) {
		if (unlocked) return@LaunchedEffect
		exporting = false
		encryptedImport = null
	}

	val export = { uri: Uri? ->
		val document = uri?.let { PickedDocument(context.contentResolver, it) }
		val written = model.exportLibrary(document?.let { it::write })
		if (document != null) {
			scope.launch { if (!written.await()) withContext(Dispatchers.IO) { runCatching { document.deleteIfEmpty() } } }
		}
	}
	val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(EXPORT_TYPE)) { export(it) }
	val saveEncrypted = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument(ENCRYPTED_EXPORT_TYPE)) { export(it) }
	val runImport = { document: PickedDocument, passphrase: String? ->
		scope.launch {
			model.importLibrary(passphrase, document::size, document::read).await()
			if (model.failure != Failure.WrongExportPassphrase) encryptedImport = null
		}
	}
	val open = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
		model.pickerClosed()
		if (uri == null) return@rememberLauncherForActivityResult
		val document = PickedDocument(context.contentResolver, uri)
		scope.launch {
			val head = withContext(Dispatchers.IO) { runCatching(document::head).getOrDefault(ByteArray(0)) }
			if (model.phase == AppModel.Phase.Unlocked && model.isEncryptedExport(head)) encryptedImport = document else runImport(document, null)
		}
	}

	if (unlocked && exporting) {
		ExportDialog(onDismiss = { exporting = false }) { passphrase ->
			exporting = false
			model.prepareExport(passphrase)
			if (passphrase == null) save.launch(resources.getString(R.string.export_file_name)) else saveEncrypted.launch(resources.getString(R.string.encrypted_export_file_name))
		}
	}
	encryptedImport?.takeIf { unlocked }?.let { document ->
		ImportPassphraseDialog(
			working = model.isImporting,
			wrong = model.failure == Failure.WrongExportPassphrase,
			onDismiss = {
				encryptedImport = null
				if (model.failure == Failure.WrongExportPassphrase) model.dismissFailure()
			},
			onEdit = { if (model.failure == Failure.WrongExportPassphrase) model.dismissFailure() },
			onImport = { passphrase ->
				if (model.failure == Failure.WrongExportPassphrase) model.dismissFailure()
				runImport(document, passphrase)
			},
		)
	}
	if (unlocked) {
		model.exchanged?.let {
			AlertDialog(
				onDismissRequest = model::dismissExchanged,
				text = { DialogBody { Text(exchangedMessage(it)) } },
				confirmButton = { TextButton(onClick = model::dismissExchanged) { Text(stringResource(R.string.ok)) } },
			)
		}
	}
	return remember(model, open) {
		LibraryPickers(
			export = { exporting = true },
			import = {
				model.prepareImport()
				open.launch(arrayOf("*/*"))
			},
		)
	}
}

@Composable
fun LibraryExchange(model: AppModel, pickers: LibraryPickers = rememberLibraryPickers(model)) {
	SettingsSection(stringResource(R.string.settings_notes), listOf(
		SettingsRow(stringResource(R.string.export_notes), stringResource(R.string.export_notes_explanation), onClick = pickers.export),
		SettingsRow(
			stringResource(R.string.import_notes),
			stringResource(if (model.isImporting) R.string.busy else R.string.import_notes_explanation),
			enabled = !model.isImporting,
			announces = model.isImporting,
			onClick = pickers.import,
		),
	))
}

@Composable
private fun ExportDialog(onDismiss: () -> Unit, onExport: (String?) -> Unit) {
	var encrypt by remember { mutableStateOf(true) }
	var opening by remember { mutableStateOf(true) }
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
			DialogBody {
				Text(stringResource(R.string.export_explanation))
				Row(
					Modifier.fillMaxWidth().toggleable(value = encrypt, role = Role.Switch, onValueChange = {
						encrypt = it
						opening = false
					}).heightIn(min = 48.dp),
					verticalAlignment = Alignment.CenterVertically,
					horizontalArrangement = Arrangement.SpaceBetween,
				) {
					Text(stringResource(R.string.encrypt_with_passphrase), Modifier.weight(1f))
					Switch(checked = encrypt, onCheckedChange = null)
				}
				if (encrypt) {
					PasswordField(passphrase, stringResource(R.string.passphrase), takesFocus = opening, imeAction = ImeAction.Next, onEdit = { mismatched = false })
					PasswordField(
						verify,
						stringResource(R.string.verify_passphrase),
						error = if (mismatched) stringResource(R.string.passphrases_mismatch) else null,
						onEdit = { mismatched = false },
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
private fun ImportPassphraseDialog(working: Boolean, wrong: Boolean, onDismiss: () -> Unit, onEdit: () -> Unit, onImport: (String) -> Unit) {
	val passphrase = remember { TextFieldState() }
	val submit = { if (passphrase.text.isNotEmpty() && !working) onImport(passphrase.text.toString()) }
	AlertDialog(
		onDismissRequest = { if (!working) onDismiss() },
		title = { Text(stringResource(R.string.import_passphrase_title)) },
		text = {
			DialogBody {
				Text(stringResource(R.string.import_passphrase_message))
				PasswordField(
					passphrase,
					stringResource(R.string.passphrase),
					enabled = !working,
					error = if (wrong) stringResource(R.string.wrong_export_passphrase) else null,
					takesFocus = true,
					onEdit = onEdit,
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
private fun exchangedMessage(exchanged: AppModel.Exchanged): String = when (exchanged) {
	is AppModel.Exchanged.Exported -> pluralStringResource(R.plurals.exported_notes, exchanged.notes, exchanged.notes)
	is AppModel.Exchanged.Imported -> summaryMessage(exchanged.summary)
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

private const val EXPORT_TYPE = "application/zip"
private const val ENCRYPTED_EXPORT_TYPE = "application/octet-stream"
