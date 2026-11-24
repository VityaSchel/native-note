package dev.hloth.nativenote.export

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.sync.WireReader
import dev.hloth.nativenote.sync.WireWriter

object ExportEnvelope {
	sealed class Failure(message: String) : Exception(message) {
		class NotAnExport : Failure("not a Native Note export")

		class NewerVersion : Failure("written by a newer Native Note")

		class ParametersOutOfBounds : Failure("Argon2 parameters out of bounds")

		class WrongPassphraseOrDamaged : Failure("wrong passphrase, or the export is damaged")
	}

	private val FAMILY = "NNEXPORT".encodeToByteArray()
	val MAGIC = FAMILY + "1".encodeToByteArray()
	const val SALT_LENGTH = 16
	private const val MAXIMUM_MEMORY = 2 * 1024 * 1024
	private const val MAXIMUM_PASSES = 10
	private const val MAXIMUM_LANES = 16
	private const val PARAMETERS_LENGTH = 12
	private const val TAG_LENGTH = 16
	private val HEADER_LENGTH = MAGIC.size + PARAMETERS_LENGTH + SALT_LENGTH
	private val MINIMUM_LENGTH = HEADER_LENGTH + AesGcm.NONCE_LENGTH + TAG_LENGTH

	fun isEncrypted(file: ByteArray) = file.startsWith(MAGIC)

	fun refuseNewerVersion(file: ByteArray) {
		if (file.size > FAMILY.size && file.startsWith(FAMILY) && !isEncrypted(file)) throw Failure.NewerVersion()
	}

	fun isWithinBounds(parameters: Argon2.Parameters) =
		parameters.p in 1..MAXIMUM_LANES && parameters.t in 1..MAXIMUM_PASSES && parameters.m in 8 * parameters.p..MAXIMUM_MEMORY

	fun seal(
		zip: ByteArray,
		passphrase: String,
		parameters: Argon2.Parameters = Argon2.Parameters.floor,
		salt: ByteArray = AesGcm.randomBytes(SALT_LENGTH),
		nonce: ByteArray = AesGcm.randomBytes(AesGcm.NONCE_LENGTH),
	): ByteArray {
		require(salt.size == SALT_LENGTH)
		if (!isWithinBounds(parameters)) throw Failure.ParametersOutOfBounds()
		val header = header(parameters, salt)
		val key = key(passphrase, salt, parameters)
		try {
			return header + AesGcm.seal(key, zip, header, nonce)
		} finally {
			key.fill(0)
		}
	}

	fun open(file: ByteArray, passphrase: String): ByteArray {
		refuseNewerVersion(file)
		if (file.size < MINIMUM_LENGTH || !isEncrypted(file)) throw Failure.NotAnExport()
		val header = file.copyOfRange(0, HEADER_LENGTH)
		val fields = WireReader(header.copyOfRange(MAGIC.size, HEADER_LENGTH))
		val parameters = Argon2.Parameters(fields.u32().toInt(), fields.u32().toInt(), fields.u32().toInt())
		if (!isWithinBounds(parameters)) throw Failure.ParametersOutOfBounds()
		val key = key(passphrase, header.copyOfRange(HEADER_LENGTH - SALT_LENGTH, HEADER_LENGTH), parameters)
		try {
			return AesGcm.open(key, file.copyOfRange(HEADER_LENGTH, file.size), header) ?: throw Failure.WrongPassphraseOrDamaged()
		} finally {
			key.fill(0)
		}
	}

	fun header(parameters: Argon2.Parameters, salt: ByteArray): ByteArray = WireWriter().apply {
		fixed(MAGIC)
		for (word in listOf(parameters.m, parameters.t, parameters.p)) u32(word.toUInt())
		fixed(salt)
	}.bytes

	fun key(passphrase: String, salt: ByteArray, parameters: Argon2.Parameters) = Argon2.hash(passphrase, salt, parameters)

	private fun ByteArray.startsWith(prefix: ByteArray) = size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }
}
