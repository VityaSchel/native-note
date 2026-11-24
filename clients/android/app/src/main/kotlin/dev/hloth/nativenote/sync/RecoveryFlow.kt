package dev.hloth.nativenote.sync

import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.UnknownHostException

class RecoveryFlow(private val connection: SyncConnection) {
	sealed class Failure(message: String) : Exception(message) {
		class RotatedElsewhere : Failure("the recovery phrase was changed on another device")

		class ServerBehind : Failure("the server holds an older recovery blob than this device pinned")

		class NoLibrary : Failure("the server holds no library")

		class OutcomeUnknown : Failure("the server's answer did not arrive")
	}

	class Stored(val v: UInt, val blob: ByteArray)

	class Joined(val contentKey: ByteArray, val pin: UInt)

	suspend fun storedVersion(): UInt = get().v

	suspend fun put(contentKey: ByteArray, recoveryKey: ByteArray, pin: UInt): UInt {
		if (pin == UInt.MAX_VALUE) throw Failure.RotatedElsewhere()
		val request = Request.Put(pin + 1u, RecoveryBlob.seal(contentKey, recoveryKey))
		var mayHaveLanded = false
		val response = try {
			sendAgainIfLost(request) { mayHaveLanded = mayHaveLanded || !neverSent(it) }
		} catch (error: IOException) {
			if (!mayHaveLanded) throw error
			return pinAfterLostAnswer(contentKey, recoveryKey, pin, error)
		} catch (error: SyncError) {
			if (error is SyncError.RequestMalformed || error is SyncError.Unsupported) throw error
			return pinAfterLostAnswer(contentKey, recoveryKey, pin, error)
		}
		if (response !is Response.Put) throw SyncError.ProtocolViolation()
		return when {
			response.status == Status.Accepted && response.v == pin + 1u -> response.v
			response.status == Status.Conflict && response.v >= pin -> {
				val stored = storedAfterPut()
				if (RecoveryBlob.open(stored.blob, recoveryKey) == null) throw Failure.RotatedElsewhere()
				stored.v
			}
			response.status == Status.Conflict -> throw Failure.ServerBehind()
			else -> throw SyncError.ProtocolViolation()
		}
	}

	suspend fun pin(contentKey: ByteArray, recoveryKey: ByteArray): UInt? {
		val stored = get()
		return if (RecoveryBlob.open(stored.blob, recoveryKey)?.contentEquals(contentKey) == true) stored.v else null
	}

	suspend fun join(recoveryKey: ByteArray): Joined? {
		val stored = get()
		if (stored.v == 0u) throw Failure.NoLibrary()
		return RecoveryBlob.open(stored.blob, recoveryKey)?.let { Joined(it, stored.v) }
	}

	private suspend fun pinAfterLostAnswer(contentKey: ByteArray, recoveryKey: ByteArray, pin: UInt, failure: Exception): UInt {
		val stored = storedAfterPut()
		if (stored.v > pin && RecoveryBlob.open(stored.blob, recoveryKey)?.contentEquals(contentKey) == true) return stored.v
		if (stored.v > pin) throw Failure.RotatedElsewhere()
		if (stored.v < pin) throw Failure.ServerBehind()
		throw failure
	}

	private suspend fun get(): Stored {
		val response = sendAgainIfLost(Request.Get)
		if (response !is Response.Get || (response.v == 0u && response.blob.isNotEmpty())) throw SyncError.ProtocolViolation()
		return Stored(response.v, response.blob)
	}

	private suspend fun storedAfterPut(): Stored = try {
		get()
	} catch (_: Exception) {
		throw Failure.OutcomeUnknown()
	}

	private suspend fun sendAgainIfLost(request: Request, lost: (IOException) -> Unit = {}): Response {
		var attempt = 1
		while (true) {
			try {
				return connection.send(request)
			} catch (error: IOException) {
				lost(error)
				if (attempt >= ATTEMPTS) throw error
				attempt++
			}
		}
	}

	private companion object {
		const val ATTEMPTS = 3

		fun neverSent(error: IOException) = error is UnknownHostException || error is ConnectException || error is NoRouteToHostException
	}
}
