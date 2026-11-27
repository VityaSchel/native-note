package dev.hloth.nativenote.model

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.hloth.nativenote.R
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.Argon2Calibration
import dev.hloth.nativenote.export.ExportEnvelope
import dev.hloth.nativenote.export.LibraryArchive
import dev.hloth.nativenote.export.ZipArchive
import dev.hloth.nativenote.storage.Note
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.commit
import dev.hloth.nativenote.storage.disconnectSync
import dev.hloth.nativenote.sync.Applied
import dev.hloth.nativenote.sync.Commit
import dev.hloth.nativenote.sync.HttpTransport
import dev.hloth.nativenote.sync.Mnemonic
import dev.hloth.nativenote.sync.PhraseEntry
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.unlock.BiometricVault
import dev.hloth.nativenote.unlock.KeystoreBiometricVault
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.Unlock
import dev.hloth.nativenote.unlock.UnlockKeys
import dev.hloth.nativenote.unlock.UnlockParameters
import dev.hloth.nativenote.unlock.UnlockRecord
import java.util.UUID
import java.util.concurrent.Executors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class AppModel(
	private val files: LibraryFiles,
	val hasSecureHardware: Boolean,
	private val makeParameters: () -> UnlockParameters,
	private val calibrate: () -> Argon2.Parameters = { Argon2Calibration.calibrateMemory() },
	private val clock: () -> Long = System::currentTimeMillis,
	private val searchNotes: (NoteStore, String) -> List<Note> = { store, text -> store.search(text) },
	private val biometricVault: BiometricVault,
	private val biometricsAvailable: () -> Boolean,
	private val exportParameters: Argon2.Parameters = Argon2.Parameters.floor,
	private val memoryAvailable: () -> Long = { Runtime.getRuntime().let { it.maxMemory() - (it.totalMemory() - it.freeMemory()) } },
	makeTransport: (String) -> SyncTransport = ::HttpTransport,
	syncDelayMillis: Long = 30_000,
	loadMnemonic: () -> Mnemonic? = { null },
) {
	enum class Phase { Loading, NeedsSetup, Locked, Unlocked }

	enum class BiometricOffer { Hidden, Prompt, Button, Prompting }

	enum class BiometricOutcome { Succeeded, Canceled, LockedOut, Unavailable }

	private class StoredKeyUnreadable(cause: Throwable) : Exception(cause)

	sealed interface Exchanged {
		data class Exported(val notes: Int) : Exchanged

		data class Imported(val summary: ImportSummary) : Exchanged
	}

	private class PendingExport(val passphrase: String?)

	private class FailingSave(val note: Note, val reason: Failure.Unexpected)

	var phase by mutableStateOf(Phase.Loading)
		private set
	var isOnboarding by mutableStateOf(false)
		private set
	var isOpening by mutableStateOf(false)
		private set
	var failure by mutableStateOf<Failure?>(null)
		private set
	var notes by mutableStateOf<List<Note>>(emptyList())
		private set
	var selection by mutableStateOf<UUID?>(null)
		private set
	var focusesEditor by mutableStateOf<UUID?>(null)
		private set
	var searchText by mutableStateOf("")
		private set
	private var matches by mutableStateOf<List<UUID>?>(null)
	var isBiometricUnlockOn by mutableStateOf(false)
		private set
	var biometricOffer by mutableStateOf(BiometricOffer.Hidden)
		private set
	var isImporting by mutableStateOf(false)
		private set
	var exchanged by mutableStateOf<Exchanged?>(null)
		private set
	val canUseBiometrics get() = biometricsAvailable()

	val selectedNote: Note? get() = selection?.let { id -> notes.firstOrNull { it.id == id } }

	private val scope = MainScope()
	private val worker = Executors.newSingleThreadExecutor { Thread(it, "library") }.asCoroutineDispatcher()
	private val scheduler = SaveScheduler(scope)
	private val sync = LibrarySync(
		scope,
		scheduler,
		worker,
		makeTransport,
		syncDelayMillis,
		clock,
		currentStore = { store },
		commit = ::commitSync,
		report = { failure = Failure.of(it, R.string.failure_sync_start) },
		mnemonic = { mnemonic },
	)

	val mnemonic: Mnemonic? by lazy(loadMnemonic)

	val syncStatus get() = sync.status

	fun syncNow(): Job = scope.launch { sync.now() }

	suspend fun prepareSync(server: String, apiKey: String) = sync.prepare(server, apiKey)

	suspend fun joinSync(server: String, apiKey: String, phrase: PhraseEntry) = sync.join(server, apiKey, phrase)

	suspend fun finishSync(answers: List<String>) = sync.finish(answers)

	suspend fun prepareRotation() = sync.prepareRotation()

	suspend fun finishRotation(answers: List<String>) = sync.finishRotation(answers)

	suspend fun adoptCurrentPhrase(phrase: PhraseEntry) = sync.adoptCurrentPhrase(phrase)

	fun cancelRecovery() = sync.cancelRecovery()

	suspend fun turnOffSync(): Failure? = scope.async {
		val store = store ?: return@async Failure.Unexpected(R.string.failure_turn_off_sync_unlock)
		sync.stop()?.join()
		try {
			withContext(worker) { store.disconnectSync() }
			null
		} catch (error: Exception) {
			sync.start(store)
			Failure.of(error, R.string.failure_turn_off_sync)
		}
	}.await()

	private var store: NoteStore? = null
	private var retiring: NoteStore? = null
	private var record: UnlockRecord? = null
	private var awayEvents = 0
	private var passwordChange: Deferred<Failure?>? = null
	private var locking: Job? = null
	private var promptOnReturn = true
	private var pickerOpen = false
	private var pendingExport: PendingExport? = null
	private val failingSaves = LinkedHashMap<UUID, FailingSave>()
	private var searchFailing = false
	private val createdThisSession = HashSet<UUID>()
	private val keptForUndo = HashMap<UUID, Note>()
	private var pendingNote: String? = null
	private val discards = HashMap<UUID, Job>()
	private val creations = HashMap<UUID, Job>()

	fun groups(grouping: NoteGrouping, results: String): List<NoteGroup> {
		val ranked = matches ?: return grouping.groups(notes)
		val byId = notes.associateBy { it.id }
		val found = ranked.mapNotNull { byId[it] }
		return if (found.isEmpty()) emptyList() else listOf(NoteGroup(results, found))
	}

	fun start(): Job = scope.launch {
		val holdsRecord = withContext(worker) { runCatching { files.record.read() != null }.getOrDefault(true) }
		phase = if (holdsRecord) Phase.Locked else Phase.NeedsSetup
	}

	fun setUp(password: String): Job = open(onboarding = true) {
		Unlock.setUp(password, files, makeParameters).also { runCatching { biometricVault.delete() } }
	}

	fun unlock(password: String): Job = open(onboarding = false) { Unlock.open(password, files) }

	fun unlockWithBiometrics(): Job = open(onboarding = false, failed = ::biometricUnlockFailed) {
		val key = try {
			biometricVault.open()
		} catch (error: Exception) {
			throw StoredKeyUnreadable(error)
		}
		try {
			Unlock.open(key, files)
		} finally {
			key.fill(0)
		}
	}

	private suspend fun biometricUnlockFailed(error: Exception): Failure = when (error) {
		is StoredKeyUnreadable -> forgetStoredKey(R.string.failure_biometric_read, error.cause)
		is Unlock.Failure.KeyRejected -> forgetStoredKey(R.string.failure_biometric_rejected, null)
		else -> {
			biometricOffer = BiometricOffer.Hidden
			Failure.of(error)
		}
	}

	private suspend fun forgetStoredKey(@StringRes reason: Int, cause: Throwable?): Failure {
		val forgotten = withContext(worker) { runCatching { biometricVault.delete() }.isSuccess }
		refreshBiometrics(prompt = false)
		if (!forgotten) biometricOffer = BiometricOffer.Hidden
		return Failure.Unexpected(reason, cause?.toString())
	}

	fun appStarted(): Job {
		val prompt = promptOnReturn
		promptOnReturn = false
		return scope.launch { refreshBiometrics(prompt) }
	}

	private suspend fun refreshBiometrics(prompt: Boolean) {
		val stored = withContext(worker) {
			runCatching {
				if (biometricVault.isStored && biometricVault.isInvalidated()) biometricVault.delete()
				biometricVault.isStored
			}.getOrDefault(false)
		}
		isBiometricUnlockOn = stored
		biometricOffer = when {
			!stored || !biometricsAvailable() -> BiometricOffer.Hidden
			prompt -> BiometricOffer.Prompt
			biometricOffer == BiometricOffer.Hidden || biometricOffer == BiometricOffer.Prompting -> BiometricOffer.Button
			else -> biometricOffer
		}
	}

	fun biometricPromptShown() {
		if (biometricOffer != BiometricOffer.Hidden) biometricOffer = BiometricOffer.Prompting
	}

	fun biometricPromptEnded(outcome: BiometricOutcome): Job {
		if (biometricOffer != BiometricOffer.Prompting) return Job().apply { complete() }
		biometricOffer = when (outcome) {
			BiometricOutcome.Succeeded, BiometricOutcome.Canceled -> BiometricOffer.Button
			BiometricOutcome.LockedOut, BiometricOutcome.Unavailable -> BiometricOffer.Hidden
		}
		if (outcome != BiometricOutcome.Succeeded || phase != Phase.Locked) return Job().apply { complete() }
		return unlockWithBiometrics()
	}

	fun enableBiometricUnlock(password: String, authenticate: suspend () -> BiometricOutcome): Deferred<Failure?> {
		val unlockedRecord = record
		if (phase != Phase.Unlocked || unlockedRecord == null) return CompletableDeferred(Failure.Unexpected(R.string.failure_biometric_unlock_first))
		if (!biometricsAvailable()) return CompletableDeferred(Failure.Unexpected(R.string.failure_biometric_unavailable))
		return scope.async {
			val key = try {
				withContext(worker) { Unlock.provenKey(password, unlockedRecord, files) }
			} catch (error: Exception) {
				return@async Failure.of(error)
			}
			try {
				withContext(worker) { biometricVault.create() }
				val outcome = authenticate()
				val confirmed = outcome == BiometricOutcome.Succeeded && record === unlockedRecord && withContext(worker) {
					biometricVault.seal(key)
					biometricVault.open().let { read -> read.contentEquals(key).also { read.fill(0) } }
				}
				if (!confirmed || record !== unlockedRecord) withContext(worker) { biometricVault.delete() }
				when {
					record !== unlockedRecord -> null
					outcome == BiometricOutcome.LockedOut -> Failure.Unexpected(R.string.failure_biometric_locked_out)
					outcome == BiometricOutcome.Unavailable -> Failure.Unexpected(R.string.failure_biometric_unavailable)
					outcome == BiometricOutcome.Succeeded && !confirmed -> Failure.Unexpected(R.string.failure_biometric_mismatch)
					else -> null
				}
			} catch (error: Exception) {
				withContext(worker) { runCatching { biometricVault.delete() } }
				Failure.Unexpected(R.string.failure_biometric_enable, error.toString())
			} finally {
				key.fill(0)
				refreshBiometrics(prompt = false)
			}
		}
	}

	fun disableBiometricUnlock(): Deferred<Failure?> = scope.async {
		val failed = withContext(worker) { runCatching { biometricVault.delete() }.exceptionOrNull() }
		refreshBiometrics(prompt = false)
		failed?.let { Failure.Unexpected(R.string.failure_biometric_disable, it.toString()) }
	}

	fun finishOnboarding() {
		isOnboarding = false
	}

	fun dismissFailure() {
		failure = null
	}

	fun dismissExchanged() {
		exchanged = null
	}

	fun appStopped() {
		if (pickerOpen) return
		screenTurnedOff()
	}

	fun screenTurnedOff() {
		pendingNote = null
		awayEvents++
		if (phase == Phase.Unlocked) lock()
		promptOnReturn = true
	}

	fun prepareExport(passphrase: String?) {
		pendingExport = PendingExport(passphrase)
		pickerOpen = true
	}

	fun prepareImport() {
		pickerOpen = true
	}

	fun pickerClosed() {
		pickerOpen = false
	}

	fun exportLibrary(write: ((ByteArray) -> Unit)?): Deferred<Boolean> {
		val pending = pendingExport
		pendingExport = null
		pickerOpen = false
		if (write == null) return CompletableDeferred(false)
		if (pending == null || phase != Phase.Unlocked || store == null) {
			failure = Failure.Unexpected(R.string.failure_export_locked, title = R.string.failure_export)
			return CompletableDeferred(false)
		}
		val passphrase = pending.passphrase
		val shown = notes
		return scope.async {
			try {
				val file = withContext(worker) {
					val archive = LibraryArchive.archive(shown)
					passphrase?.let { ExportEnvelope.seal(archive, it, exportParameters) } ?: archive
				}
				if (file.size > LibraryArchive.MAXIMUM_SIZE) throw ZipArchive.Failure.TooLarge()
				withContext(Dispatchers.IO) { write(file) }
				exchanged = Exchanged.Exported(shown.size)
				true
			} catch (error: Exception) {
				failure = Failure.of(error, R.string.failure_export)
				false
			} catch (_: OutOfMemoryError) {
				failure = Failure.of(TooLargeForDevice(), R.string.failure_export)
				false
			}
		}
	}

	fun isEncryptedExport(head: ByteArray) = ExportEnvelope.isEncrypted(head)

	fun importLibrary(passphrase: String?, size: () -> Long, read: () -> ByteArray): Deferred<ImportSummary?> {
		pickerOpen = false
		if (isImporting) return CompletableDeferred(value = null)
		val store = store
		if (store == null) {
			failure = Failure.Unexpected(R.string.failure_import_locked, title = R.string.failure_import)
			return CompletableDeferred(value = null)
		}
		isImporting = true
		return scope.async {
			try {
				import(store, passphrase, size, read)?.also { exchanged = Exchanged.Imported(it) }
			} finally {
				isImporting = false
			}
		}
	}

	private suspend fun import(store: NoteStore, passphrase: String?, size: () -> Long, read: () -> ByteArray): ImportSummary? {
		val incoming = try {
			val file = withContext(Dispatchers.IO) {
				val bytes = size()
				if (bytes > LibraryArchive.MAXIMUM_SIZE) throw LibraryArchive.Failure.TooLarge()
				if (bytes * IMPORT_MEMORY_FACTOR > memoryAvailable()) throw TooLargeForDevice()
				read()
			}
			withContext(worker) {
				ExportEnvelope.refuseNewerVersion(file)
				LibraryArchive.notes(passphrase?.let { ExportEnvelope.open(file, it) } ?: file)
			}
		} catch (error: Exception) {
			failure = Failure.of(error, R.string.failure_import)
			return null
		} catch (_: OutOfMemoryError) {
			failure = Failure.of(TooLargeForDevice(), R.string.failure_import)
			return null
		}
		if (store !== this.store) return ImportSummary(notImported = incoming.size)
		val added = try {
			withContext(worker) { store.insertMissing(incoming) }
		} catch (error: Exception) {
			if (store !== this.store) return ImportSummary(notImported = incoming.size)
			failure = Failure.of(error, R.string.failure_import)
			return null
		}
		if (store === this.store) {
			val shown = notes.mapTo(HashSet()) { it.id }
			notes = notes + added.filter { it.id !in shown }
			refreshSearch()
			sync.soon()
		}
		return ImportSummary(added = added.size, skipped = incoming.size - added.size)
	}

	fun lock(): Job {
		val closing = store
		val changing = passwordChange
		changing?.cancel()
		val syncing = sync.stop()
		if (phase == Phase.Unlocked) phase = Phase.Locked
		select(null)
		notes = emptyList()
		createdThisSession.clear()
		keptForUndo.clear()
		focusesEditor = null
		isOnboarding = false
		store = null
		failure = null
		failingSaves.clear()
		searchFailing = false
		record = null
		pendingExport = null
		if (biometricOffer != BiometricOffer.Hidden) biometricOffer = BiometricOffer.Button
		val previous = locking
		return scope.launch {
			previous?.join()
			scheduler.flushAll()
			syncing?.join()
			changing?.join()
			while (creations.isNotEmpty()) creations.values.first().join()
			while (discards.isNotEmpty()) discards.values.first().join()
			if (closing == null) return@launch
			if (failingSaves.isEmpty()) withContext(worker) { closing.connection.close() } else retiring = closing
		}.also { locking = it }
	}

	fun erase(): Job = scope.launch {
		if (phase != Phase.Locked || isOpening) return@launch
		isOpening = true
		try {
			locking?.join()
			passwordChange?.join()
			retiring?.let {
				retiring = null
				withContext(worker) { it.connection.close() }
			}
			scheduler.discardAll()
			failingSaves.clear()
			failure = null
			searchText = ""
			matches = null
			val failed = withContext(worker) {
				val vault = runCatching { biometricVault.delete() }.exceptionOrNull()?.let { listOf(KeystoreBiometricVault.FILE_NAME) }.orEmpty()
				vault + files.erase()
			}
			isBiometricUnlockOn = false
			biometricOffer = BiometricOffer.Hidden
			if (failed.isNotEmpty()) failure = Failure.Unexpected(R.string.failure_erase, failed.joinToString())
			phase = Phase.NeedsSetup
		} finally {
			isOpening = false
		}
	}

	fun changePassword(current: String, new: String): Deferred<Failure?> {
		val unlockedRecord = record
		if (phase != Phase.Unlocked || unlockedRecord == null) return CompletableDeferred(Failure.Unexpected(R.string.failure_unlock_first))
		if (passwordChange != null) return CompletableDeferred(Failure.Unexpected(R.string.failure_password_change_running))
		val change = scope.async {
			try {
				val changed = withContext(worker) {
					Unlock.changePassword(current, new, unlockedRecord, files, calibrate) { ensureActive() }
				}
				if (record === unlockedRecord) record = changed
				null
			} catch (_: CancellationException) {
				Failure.Unexpected(R.string.failure_password_not_changed)
			} catch (error: Exception) {
				Failure.of(error)
			}
		}
		passwordChange = change
		change.invokeOnCompletion { passwordChange = null }
		return change
	}

	fun createNote(body: String = ""): Job {
		val store = store ?: return scope.launch {}
		val now = clock()
		val note = Note(UUID.randomUUID(), body, now, now, dirty = body.isNotEmpty())
		val creating = scope.launch {
			try {
				create(note, store)
			} finally {
				creations.remove(note.id)
			}
		}
		creations[note.id] = creating
		return creating
	}

	private suspend fun create(note: Note, store: NoteStore) {
		if (!write(R.string.failure_create) { it.save(note) }) return
		if (store !== this.store) {
			if (note.body.isBlank()) discard(note, store)
			return
		}
		if (searchText.isNotEmpty()) updateSearch("")
		notes = listOf(note) + notes
		createdThisSession += note.id
		select(note.id)
		focusesEditor = note.id
		if (note.dirty) sync.soon()
	}

	fun editorTookFocus() {
		focusesEditor = null
	}

	fun select(id: UUID?) {
		val previous = selection
		selection = id
		if (focusesEditor != id) focusesEditor = null
		if (previous == null || previous == id) return
		val leftEmpty = emptyNewNote(previous)
		createdThisSession -= previous
		if (leftEmpty == null) {
			if (!scheduler.isHeld) scope.launch { scheduler.flush(previous) }
			return
		}
		notes = notes.filter { it.id != previous }
		val store = store ?: return
		discards[previous] = scope.launch {
			try {
				discard(leftEmpty, store)
			} finally {
				discards.remove(previous)
			}
		}
	}

	private fun emptyNewNote(id: UUID): Note? {
		if (id !in createdThisSession) return null
		return notes.firstOrNull { it.id == id }?.takeIf { it.body.isBlank() }
	}

	private suspend fun discard(note: Note, store: NoteStore) {
		scheduler.discard(note.id)
		try {
			withContext(worker) { store.discardUnsynced(note.id, note.v, clock()) }
		} catch (error: Exception) {
			if (store === this.store) failure = Failure.of(error, R.string.failure_discard)
		}
	}

	fun edit(id: UUID, body: String, shownAt: Long? = null) {
		val index = notes.indexOfFirst { it.id == id }
		if (index < 0 || notes[index].body == body) return
		val edited = notes[index].copy(body = body, updatedAt = clock(), dirty = true).withV(shownAt ?: notes[index].v)
		notes = notes.toMutableList().also { it[index] = edited }
		scheduleSave(edited, store ?: return)
		sync.soon()
	}

	fun keepForUndo(id: UUID): UUID? {
		keptForUndo[id] = notes.firstOrNull { it.id == id } ?: return null
		return id
	}

	fun restore(kept: UUID, selects: Boolean = true): UUID? {
		val store = store ?: return null
		if (notes.any { it.id == kept }) return null
		val note = keptForUndo.remove(kept)?.unsyncedCopy() ?: return null
		notes = notes + note
		if (selects) select(note.id)
		scheduleSave(note, store)
		sync.soon()
		val ranked = matches
		if (ranked != null) {
			val rank = ranked.indexOf(kept)
			if (rank >= 0) {
				matches = ranked.toMutableList().also { it[rank] = note.id }
			} else {
				scope.launch {
					scheduler.flush(note.id)
					runSearch()
				}
			}
		}
		return note.id
	}

	fun requestNote(text: String) {
		pendingNote = text
		if (phase == Phase.Unlocked) createPendingNote()
	}

	private fun createPendingNote() {
		val text = pendingNote ?: return
		pendingNote = null
		createNote(text)
	}

	fun delete(id: UUID): Deferred<Boolean> {
		createdThisSession -= id
		if (selection == id) select(null)
		val shown = notes.firstOrNull { it.id == id }
		notes = notes.filter { it.id != id }
		return scope.async {
			if (!write(R.string.failure_delete) { it.markDeleted(id, clock()) }) {
				keptForUndo.remove(id)
				if (shown != null && store != null && notes.none { it.id == id }) notes = notes + shown
				return@async false
			}
			scheduler.discard(id)
			notes = notes.filter { it.id != id }
			sync.soon()
			true
		}
	}

	fun updateSearch(text: String) {
		if (text == searchText) return
		searchText = text
		if (text.isEmpty()) {
			matches = null
			searchFailing = false
			return
		}
		scope.launch { runSearch() }
	}

	private suspend fun runSearch() {
		val store = store ?: return
		val text = searchText
		if (text.isEmpty()) return
		try {
			val found = withContext(worker) { searchNotes(store, text).map { it.id } }
			if (text != searchText || store !== this.store) return
			matches = found
			searchFailing = false
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			if (text != searchText || store !== this.store) return
			matches = emptyList()
			if (!searchFailing) failure = Failure.of(error, R.string.failure_search)
			searchFailing = true
		}
	}

	private suspend fun refreshSearch() {
		if (matches != null) runSearch()
	}

	suspend fun flushPendingSaves() = scheduler.flushAll()

	private fun scheduleSave(note: Note, store: NoteStore) {
		scheduler.schedule(note.id) {
			try {
				val saved = withContext(worker) { store.save(note) }
				if (saved is NoteStore.Saved.Copied) saveBecameCopy(note, saved.id, store)
				saveLanded(note.id, store)
				true
			} catch (error: Exception) {
				saveFailed(note, store, error)
				false
			}
		}
	}

	private suspend fun commitSync(commit: Commit, store: NoteStore): Applied {
		scheduler.hold()
		try {
			scheduler.flushAll()
			return withContext(NonCancellable) {
				val applied = withContext(worker) { store.commit(commit) }
				reconcile(applied, store)
				if (applied.pulled.isNotEmpty() || applied.copies.isNotEmpty()) refreshSearch()
				applied
			}
		} finally {
			scheduler.release()
		}
	}

	private fun reconcile(applied: Applied, store: NoteStore) {
		if (store !== this.store) return
		val copies = applied.copies.values.toSet()
		for ((id, row) in applied.changed) {
			if (scheduler.isPending(id) && id in applied.pulled) {
				moveEdit(id, applied.copies[id] ?: UUID.randomUUID(), store)
			} else if (scheduler.isPending(id)) {
				val index = notes.indexOfFirst { it.id == id }
				if (index >= 0) {
					notes = notes.toMutableList().also { it[index] = it[index].withV(row.v) }
					continue
				}
			}
			if (id !in applied.pulled && id !in copies && notes.none { it.id == id }) continue
			show(row)
		}
		for ((original, copy) in applied.copies) if (selection == original) select(copy)
	}

	private suspend fun saveBecameCopy(note: Note, copy: UUID, store: NoteStore) {
		if (store !== this.store) return
		val shown = notes.firstOrNull { it.id == note.id }
		if (shown == null || shown.v != note.v) {
			show(note.unsyncedCopy(copy))
			if (selection == note.id) select(copy)
			return
		}
		moveEdit(note.id, copy, store)
		try {
			val original = withContext(worker) { store.note(note.id) }
			if (original != null && shown in notes) show(original)
		} catch (error: Exception) {
			if (store === this.store) failure = Failure.of(error, R.string.failure_read_note)
		}
	}

	private fun moveEdit(id: UUID, copyId: UUID, store: NoteStore) {
		val edit = notes.firstOrNull { it.id == id }?.unsyncedCopy(copyId) ?: return
		scheduler.cancel(id)
		show(edit)
		scheduleSave(edit, store)
		if (selection == id) select(copyId)
	}

	private fun show(note: Note) {
		val index = notes.indexOfFirst { it.id == note.id }
		notes = when {
			index >= 0 && !note.deleted -> notes.toMutableList().also { it[index] = note }
			index >= 0 -> notes.filterIndexed { position, _ -> position != index }
			!note.deleted -> notes + note
			else -> return
		}
	}

	private suspend fun saveLanded(id: UUID, landed: NoteStore) {
		failingSaves.remove(id)
		if (failingSaves.isNotEmpty()) return
		if (failure is Failure.Unsaved) failure = null
		if (landed !== retiring) return
		retiring = null
		withContext(worker) { landed.connection.close() }
	}

	private fun saveFailed(failed: Note, store: NoteStore, error: Exception) {
		val reason = Failure.reason(error)
		if (failingSaves.isEmpty()) failure = Failure.Unsaved(reason)
		val latest = newer(notes.firstOrNull { it.id == failed.id }, failed)
		failingSaves[failed.id] = FailingSave(latest, reason)
		scheduleSave(latest, this.store ?: store)
	}

	private suspend fun write(@StringRes title: Int, body: (NoteStore) -> Unit): Boolean {
		val store = store ?: return false
		return try {
			withContext(worker) { body(store) }
			true
		} catch (error: Exception) {
			if (store === this.store) failure = Failure.of(error, title)
			false
		}
	}

	private fun open(
		onboarding: Boolean,
		failed: suspend (Exception) -> Failure = { Failure.of(it) },
		open: () -> Unlock.Unlocked,
	): Job = scope.launch {
		if (isOpening) return@launch
		isOpening = true
		if (failure !is Failure.Unexpected) failure = null
		val away = awayEvents
		try {
			locking?.join()
			passwordChange?.join()
			val unlocked = withContext(worker) { open() }
			val opened = NoteStore(unlocked.connection)
			val loaded = withContext(worker) {
				try {
					opened.liveNotes()
				} catch (error: Exception) {
					opened.connection.close()
					throw error
				}
			}
			if (away != awayEvents) {
				withContext(worker) { opened.connection.close() }
				phase = Phase.Locked
				return@launch
			}
			store = opened
			record = unlocked.record
			notes = loaded.map { note -> failingSaves[note.id]?.let { newer(it.note, note) } ?: note }
			for (note in notes) if (note.id in failingSaves) scheduleSave(note, opened)
			retiring?.let {
				retiring = null
				withContext(worker) { it.connection.close() }
			}
			failingSaves.values.firstOrNull()?.let { failure = Failure.Unsaved(it.reason) }
			runSearch()
			if (away != awayEvents) {
				lock()
				return@launch
			}
			isOnboarding = onboarding
			phase = Phase.Unlocked
			createPendingNote()
			sync.start(opened)
		} catch (error: Exception) {
			if (error is Unlock.Failure.AlreadySetUp) phase = Phase.Locked
			failure = failed(error)
		} finally {
			isOpening = false
		}
	}

	companion object {
		private const val IMPORT_MEMORY_FACTOR = 4

		private fun newer(held: Note?, other: Note) = if (held != null && held.dirty && held.updatedAt > other.updatedAt) held else other

		fun parameters(strongBox: Boolean): () -> UnlockParameters = { UnlockKeys.makeParameters(strongBox) }
	}
}
