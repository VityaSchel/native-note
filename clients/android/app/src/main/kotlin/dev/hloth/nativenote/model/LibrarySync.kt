package dev.hloth.nativenote.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.storage.KeptLibrary
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SyncAlreadySetUp
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.storage.keptLibrary
import dev.hloth.nativenote.storage.moveSync
import dev.hloth.nativenote.storage.pin
import dev.hloth.nativenote.storage.reattachSync
import dev.hloth.nativenote.storage.setPin
import dev.hloth.nativenote.storage.syncSettings
import dev.hloth.nativenote.sync.Applied
import dev.hloth.nativenote.sync.Commit
import dev.hloth.nativenote.sync.EnvelopeKey
import dev.hloth.nativenote.sync.Mnemonic
import dev.hloth.nativenote.sync.PhraseEntry
import dev.hloth.nativenote.sync.RecoveryFlow
import dev.hloth.nativenote.sync.SyncConnection
import dev.hloth.nativenote.sync.SyncEngine
import dev.hloth.nativenote.sync.SyncError
import dev.hloth.nativenote.sync.SyncProblem
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SyncStatus(
	val phase: Phase = Phase.Off,
	val server: String? = null,
	val lastSynced: Long? = null,
	val problems: List<SyncProblem> = emptyList(),
	val lastFailure: Throwable? = null,
) {
	sealed interface Phase {
		data object Off : Phase

		data object Idle : Phase

		data object Syncing : Phase

		data class Failed(val reason: Throwable) : Phase
	}
}

class LibrarySync(
	private val scope: CoroutineScope,
	private val scheduler: SaveScheduler,
	private val worker: CoroutineDispatcher,
	private val makeTransport: (String) -> SyncTransport,
	private val syncDelayMillis: Long,
	private val clock: () -> Long,
	private val currentStore: () -> NoteStore?,
	private val commit: suspend (Commit, NoteStore) -> Applied,
	private val report: (Throwable) -> Unit,
	private val mnemonic: () -> Mnemonic?,
) {
	private class RecoverySession(val settings: SyncSettings, val recoveryKey: ByteArray, val phrase: RecoveryPhrase, var movesToEmptyServer: Boolean = false)

	var status by mutableStateOf(SyncStatus())
		private set

	private var engine: SyncEngine? = null
	private var syncLoop: Job? = null
	private var idleSync: Job? = null
	private var syncRequests = 0
	private var syncedThrough = 0
	private var serverChange: Deferred<SetupResult<SetupStart>>? = null
	private var recovery: RecoverySession? = null

	suspend fun now() {
		val wanted = ++syncRequests
		if (syncLoop == null) {
			syncLoop = scope.launch {
				while (syncedThrough < syncRequests && isActive) {
					val covered = syncRequests
					once()
					syncedThrough = covered
				}
			}.also { it.invokeOnCompletion { syncLoop = null } }
		}
		while (syncedThrough < wanted) (syncLoop ?: break).join()
	}

	private suspend fun once() {
		val engine = engine ?: return
		val store = currentStore() ?: return
		idleSync?.cancel()
		status = status.copy(phase = SyncStatus.Phase.Syncing)
		scheduler.flushAll()
		try {
			val applied = engine.sync { commit(it, store) }
			if (store !== currentStore() || engine !== this.engine) return
			status = status.copy(phase = SyncStatus.Phase.Idle, lastSynced = clock(), problems = applied.problems.distinct(), lastFailure = null)
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			if (store !== currentStore() || engine !== this.engine) return
			status = status.copy(phase = SyncStatus.Phase.Failed(error), lastFailure = error)
		}
	}

	fun soon() {
		if (engine == null) return
		idleSync?.cancel()
		idleSync = scope.launch {
			delay(syncDelayMillis)
			idleSync = null
			now()
		}
	}

	suspend fun start(store: NoteStore) {
		val settings = try {
			withContext(worker) { store.syncSettings() }
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			if (store === currentStore()) report(error)
			return
		} ?: return
		if (store !== currentStore()) return
		engine = SyncEngine(store, settings, makeTransport(settings.server), worker)
		status = SyncStatus(SyncStatus.Phase.Idle, settings.server)
		scope.launch { now() }
	}

	fun stop(): Job? {
		val loop = syncLoop
		val change = serverChange
		loop?.cancel()
		change?.cancel()
		serverChange = null
		idleSync?.cancel()
		idleSync = null
		engine = null
		recovery = null
		status = SyncStatus()
		if (loop == null && change == null) return null
		return scope.launch {
			loop?.join()
			change?.join()
		}
	}

	suspend fun prepare(server: String, apiKey: String): SetupResult<SetupStart> = guarded {
		val (address, key) = endpoint(server, apiKey)
		val store = currentStore()
		val kept = store?.let { withContext(worker) { it.keptLibrary() } }
		if (store != null && kept != null) return@guarded changeServer(kept, address, key, store)
		val settings = SyncSettings(address, key, AesGcm.randomBytes(32))
		if (flow(settings.server, settings.apiKey).storedVersion() != 0u) return@guarded SetupResult.Ok(SetupStart.ExistingLibrary)
		newPhrase(settings)?.let { SetupResult.Ok(SetupStart.NewLibrary(it)) } ?: SetupResult.Err(SetupFailure.WordlistMissing)
	}

	suspend fun join(server: String, apiKey: String, phrase: PhraseEntry): SetupFailure? {
		val store = currentStore()
		if (store == null || engine != null) return SetupFailure.AlreadySetUp
		val recoveryKey = phrase.key ?: return SetupFailure.PhraseDoesNotOpen
		try {
			val (address, key) = endpoint(server, apiKey)
			val joined = flow(address, key).join(recoveryKey) ?: return SetupFailure.PhraseDoesNotOpen
			withContext(NonCancellable) {
				withContext(worker) { store.enableSync(SyncSettings(address, key, joined.contentKey), joined.pin) }
				recovery = null
				start(store)
			}
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			return setupFailure(error)
		} finally {
			recoveryKey.fill(0)
		}
		return null
	}

	suspend fun finish(answers: List<String>): SetupFailure? {
		val store = currentStore()
		val session = recovery
		if (store == null || session == null || (engine != null && !session.movesToEmptyServer)) return SetupFailure.StartAgain
		if (!matches(answers, session.phrase)) return SetupFailure.WordsDoNotMatch
		try {
			val pin = flow(session.settings.server, session.settings.apiKey).put(session.settings.contentKey, session.recoveryKey, 0u)
			if (session.movesToEmptyServer) {
				stop()?.join()
				withContext(worker) { store.moveSync(session.settings, pin) }
			} else {
				withContext(worker) { store.enableSync(session.settings, pin) }
			}
		} catch (_: RecoveryFlow.Failure.RotatedElsewhere) {
			return SetupFailure.ServerHasLibrary
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			return setupFailure(error)
		}
		recovery = null
		start(store)
		return null
	}

	suspend fun prepareRotation(): SetupResult<RecoveryPhrase> = guarded {
		val store = currentStore() ?: return@guarded SetupResult.Err(SetupFailure.StartAgain)
		val settings = withContext(worker) { store.syncSettings() } ?: return@guarded SetupResult.Err(SetupFailure.NotSetUp)
		newPhrase(settings)?.let { SetupResult.Ok(it) } ?: SetupResult.Err(SetupFailure.WordlistMissing)
	}

	suspend fun finishRotation(answers: List<String>): SetupFailure? {
		val store = currentStore()
		val session = recovery
		if (store == null || session == null) return SetupFailure.StartAgain
		if (!matches(answers, session.phrase)) return SetupFailure.WordsDoNotMatch
		try {
			val pinned = withContext(worker) { store.pin() }
			val pin = flow(session.settings.server, session.settings.apiKey).put(session.settings.contentKey, session.recoveryKey, pinned)
			withContext(worker) { store.setPin(pin) }
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			return setupFailure(error)
		}
		recovery = null
		return null
	}

	suspend fun adoptCurrentPhrase(phrase: PhraseEntry): SetupFailure? {
		val store = currentStore() ?: return SetupFailure.NotSetUp
		val recoveryKey = phrase.key ?: return SetupFailure.PhraseDoesNotOpen
		try {
			val settings = withContext(worker) { store.syncSettings() } ?: return SetupFailure.NotSetUp
			val pin = flow(settings.server, settings.apiKey).pin(settings.contentKey, recoveryKey) ?: return SetupFailure.PhraseDoesNotOpen
			withContext(worker) { store.setPin(pin) }
		} catch (cancelled: CancellationException) {
			throw cancelled
		} catch (error: Exception) {
			return setupFailure(error)
		} finally {
			recoveryKey.fill(0)
		}
		return null
	}

	fun cancelRecovery() {
		recovery = null
		serverChange?.cancel()
		serverChange = null
	}

	private suspend fun changeServer(kept: KeptLibrary, server: String, apiKey: ByteArray, store: NoteStore): SetupResult<SetupStart> {
		val change = scope.async { guarded { reattachOrMove(kept, server, apiKey, store) } }
		serverChange = change
		val result = change.await()
		if (serverChange === change) serverChange = null
		return result
	}

	private suspend fun reattachOrMove(kept: KeptLibrary, server: String, apiKey: ByteArray, store: NoteStore): SetupResult<SetupStart> {
		val connection = SyncConnection(apiKey, makeTransport(server))
		val stored = RecoveryFlow(connection).storedVersion()
		if (stored == 0u) {
			val phrase = newPhrase(SyncSettings(server, apiKey, kept.contentKey)) ?: return SetupResult.Err(SetupFailure.WordlistMissing)
			recovery?.movesToEmptyServer = true
			return SetupResult.Ok(SetupStart.NewLibrary(phrase))
		}
		if (stored < kept.pin) return SetupResult.Err(SetupFailure.ServerBehind)
		if (kept.mark != null && !SyncEngine.holds(kept.mark, connection, kept.since)) return SetupResult.Err(SetupFailure.ServerHoldsAnotherLibrary)
		currentCoroutineContext().ensureActive()
		withContext(NonCancellable) {
			withContext(worker) { store.reattachSync(server, apiKey) }
			if (store === currentStore()) {
				serverChange = null
				stop()?.join()
				start(store)
			}
		}
		return SetupResult.Ok(SetupStart.Reattached)
	}

	private fun newPhrase(settings: SyncSettings): RecoveryPhrase? {
		val mnemonic = mnemonic() ?: return null
		val recoveryKey = AesGcm.randomBytes(32)
		val words = mnemonic.words(recoveryKey)
		val phrase = RecoveryPhrase(words, words.indices.shuffled().take(3).sorted())
		recovery = RecoverySession(settings, recoveryKey, phrase)
		return phrase
	}

	private fun flow(server: String, apiKey: ByteArray) = RecoveryFlow(SyncConnection(apiKey, makeTransport(server)))

	private suspend fun <T> guarded(body: suspend () -> SetupResult<T>): SetupResult<T> = try {
		body()
	} catch (cancelled: CancellationException) {
		throw cancelled
	} catch (error: Exception) {
		SetupResult.Err(setupFailure(error))
	}

	private class InvalidEndpoint(val failure: SetupFailure) : Exception()

	private companion object {
		fun matches(answers: List<String>, phrase: RecoveryPhrase) =
			answers.size == phrase.positionsToConfirm.size && answers.zip(phrase.positionsToConfirm).all { (answer, position) -> answer.trim().lowercase() == phrase.words[position] }

		fun endpoint(server: String, apiKey: String): Pair<String, ByteArray> {
			val address = SyncSettings.server(server.trim()) ?: throw InvalidEndpoint(SetupFailure.InvalidServer)
			val key = EnvelopeKey.apiKey(apiKey) ?: throw InvalidEndpoint(SetupFailure.InvalidApiKey)
			return address to key
		}

		fun setupFailure(error: Exception): SetupFailure = when (error) {
			is InvalidEndpoint -> error.failure
			is SyncAlreadySetUp -> SetupFailure.AlreadySetUp
			is RecoveryFlow.Failure.NoLibrary -> SetupFailure.ServerHasNoLibrary
			is RecoveryFlow.Failure.RotatedElsewhere -> SetupFailure.RotatedElsewhere
			is RecoveryFlow.Failure.ServerBehind -> SetupFailure.ServerBehind
			is RecoveryFlow.Failure.OutcomeUnknown -> SetupFailure.OutcomeUnknown
			is SyncError.Unopenable -> SetupFailure.Refused
			is SyncError.Refused -> if (error.status == 400) SetupFailure.Refused else SetupFailure.Answered(error.status)
			is IOException -> SetupFailure.Unreachable(error.message.orEmpty())
			else -> SetupFailure.Failed(error)
		}
	}
}
