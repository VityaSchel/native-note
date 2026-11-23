package dev.hloth.nativenote.sync

import dev.hloth.nativenote.crypto.AesGcm
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext

fun interface SyncTransport {
	suspend fun post(body: ByteArray): ByteArray
}

sealed class SyncError(message: String) : Exception(message) {
	class Refused(val status: Int) : SyncError("the server answered HTTP $status")

	class Unopenable : SyncError("the reply does not open with this API key")

	class RequestMalformed : SyncError("the server could not read the request")

	class Unsupported : SyncError("the server needs a newer client")

	class ServerFault : SyncError("the server could not store the changes")

	class ProtocolViolation : SyncError("the server's reply breaks the protocol")

	companion object {
		fun of(reason: ErrorReason): SyncError = when (reason) {
			ErrorReason.Malformed -> RequestMalformed()
			ErrorReason.Unsupported -> Unsupported()
			ErrorReason.Fault -> ServerFault()
		}
	}
}

class HttpTransport(private val server: String) : SyncTransport {
	override suspend fun post(body: ByteArray): ByteArray = coroutineScope {
		val connection = withContext(Dispatchers.IO) { URL(server).openConnection() as HttpURLConnection }
		val exchange = async(Dispatchers.IO) { exchange(connection, body) }
		try {
			exchange.await()
		} catch (cancelled: CancellationException) {
			connection.disconnect()
			throw cancelled
		}
	}

	private fun exchange(connection: HttpURLConnection, body: ByteArray): ByteArray {
		try {
			connection.requestMethod = "POST"
			connection.instanceFollowRedirects = false
			connection.useCaches = false
			connection.connectTimeout = TIMEOUT_MILLISECONDS
			connection.readTimeout = TIMEOUT_MILLISECONDS
			connection.doOutput = true
			connection.setFixedLengthStreamingMode(body.size)
			for ((name, value) in HEADERS) connection.setRequestProperty(name, value)
			connection.outputStream.use { it.write(body) }
			val status = connection.responseCode
			if (status != 200) throw SyncError.Refused(status)
			return connection.inputStream.use { it.readBytes() }
		} finally {
			connection.disconnect()
		}
	}

	companion object {
		val HEADERS = listOf(
			"User-Agent" to "native-note",
			"Accept" to "*/*",
			"Accept-Language" to "*",
			"Accept-Encoding" to "identity",
			"Content-Type" to "application/octet-stream",
		)
		private const val TIMEOUT_MILLISECONDS = 30_000
	}
}

class SyncConnection(apiKey: ByteArray, private val transport: SyncTransport) {
	private val envelope = EnvelopeKey.fromApiKey(apiKey)

	suspend fun send(request: Request): Response {
		val nonce = AesGcm.randomBytes(AesGcm.NONCE_LENGTH)
		val reply = transport.post(envelope.seal(request.encoded(), nonce))
		val inner = envelope.open(reply, nonce) ?: throw SyncError.Unopenable()
		val response = try {
			Response.decode(inner)
		} catch (_: Exception) {
			throw SyncError.ProtocolViolation()
		}
		if (response is Response.Error) throw SyncError.of(response.reason)
		return response
	}
}
