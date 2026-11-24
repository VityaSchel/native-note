package dev.hloth.nativenote.support

import dev.hloth.nativenote.conformance.RequestDecoding
import dev.hloth.nativenote.conformance.responseBytes
import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.KeyDerivation
import dev.hloth.nativenote.storage.NoteStore
import dev.hloth.nativenote.storage.SQLiteConnection
import dev.hloth.nativenote.storage.enableSync
import dev.hloth.nativenote.sync.Content
import dev.hloth.nativenote.sync.NoteCipher
import dev.hloth.nativenote.sync.Padding
import dev.hloth.nativenote.sync.Request
import dev.hloth.nativenote.sync.Response
import dev.hloth.nativenote.sync.Status
import dev.hloth.nativenote.sync.SyncSettings
import dev.hloth.nativenote.sync.SyncTransport
import dev.hloth.nativenote.sync.Write
import dev.hloth.nativenote.sync.WriteResult
import dev.hloth.nativenote.unlock.LibraryFiles
import dev.hloth.nativenote.unlock.UnlockKeys
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class FakeServer(
	private val apiKey: ByteArray = AesGcm.randomBytes(32),
	val contentKey: ByteArray = AesGcm.randomBytes(32),
) : SyncTransport {
	private val envelopeKey = KeyDerivation.derive(apiKey, info = KeyDerivation.ENVELOPE)
	private val cipher = NoteCipher(contentKey)
	private val log = mutableListOf<Write>()

	val apiKeyHex = apiKey.toHexString()
	@Volatile
	var blobVersion = 0u
	@Volatile
	var blob = ByteArray(0)
	@Volatile
	var requests = 0
		private set
	@Volatile
	var beforeReply: suspend (Request) -> Unit = {}

	fun settings(server: String = ADDRESS) = SyncSettings(server, apiKey, contentKey)

	fun enableSync(directory: File, password: String) {
		val files = LibraryFiles(directory)
		SQLiteConnection(files.database, UnlockKeys.databaseKey(password, files.record.read()!!), create = false).use {
			NoteStore(it).enableSync(settings(), 0u)
		}
	}

	fun store(content: Content, v: UInt) = synchronized(log) { log += cipher.seal(content, v) }

	fun bodies(): List<String> = synchronized(log) { log.mapNotNull { (cipher.open(it) as? Content.Note)?.body } }

	override suspend fun post(body: ByteArray): ByteArray = withContext(Dispatchers.IO) {
		requests++
		val request = RequestDecoding.decode(Padding.unpad(AesGcm.open(envelopeKey, body)!!)!!)
		val response = answer(request)
		beforeReply(request)
		AesGcm.seal(envelopeKey, Padding.pad(responseBytes(response))!!, aad = body.copyOf(AesGcm.NONCE_LENGTH))
	}

	private fun answer(request: Request): Response = when (request) {
		Request.Get -> Response.Get(blobVersion, blob)
		is Request.Put -> if (request.v == blobVersion + 1u) {
			blobVersion = request.v
			blob = request.blob
			Response.Put(Status.Accepted, request.v)
		} else {
			Response.Put(Status.Conflict, blobVersion)
		}
		is Request.Sync -> synchronized(log) {
			val results = request.writes.map { write ->
				val latest = log.filter { it.blindedId.contentEquals(write.blindedId) }.maxOfOrNull { it.v } ?: 0u
				if (write.v == latest + 1u) {
					log += write
					WriteResult(Status.Accepted, write.v)
				} else {
					WriteResult(Status.Conflict, latest)
				}
			}
			Response.Sync(results, log.drop(request.since.toInt()), log.size.toULong(), more = false)
		}
	}

	companion object {
		const val ADDRESS = "http://127.0.0.1:9/"
	}
}
