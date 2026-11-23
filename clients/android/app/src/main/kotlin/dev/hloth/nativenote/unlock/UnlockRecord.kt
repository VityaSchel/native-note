package dev.hloth.nativenote.unlock

import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.DatabaseKeyWrap
import dev.hloth.nativenote.crypto.MachineKey
import dev.hloth.nativenote.sync.WireException
import dev.hloth.nativenote.sync.WireReader
import dev.hloth.nativenote.sync.WireWriter

class UnlockParameters(val localSalt: ByteArray, val argon: Argon2.Parameters, val machineKeyId: ByteArray?) {
	override fun equals(other: Any?) = other is UnlockParameters && localSalt.contentEquals(other.localSalt) && argon == other.argon &&
		(machineKeyId?.contentEquals(other.machineKeyId) ?: (other.machineKeyId == null))

	override fun hashCode() = listOf(localSalt.contentHashCode(), argon, machineKeyId?.contentHashCode()).hashCode()

	companion object {
		const val SALT_LENGTH = 16
	}
}

class UnlockRecord(val parameters: UnlockParameters, val wrappedKey: ByteArray) {
	class Unreadable(val isNewerVersion: Boolean, reason: String) : Exception("the unlock record is unreadable: $reason")

	fun encoded(): ByteArray {
		val writer = WireWriter()
		writer.u8(VERSION)
		writer.fixed(parameters.localSalt)
		writer.u32(parameters.argon.m.toUInt())
		writer.u32(parameters.argon.t.toUInt())
		writer.u32(parameters.argon.p.toUInt())
		writer.u8(if (parameters.machineKeyId == null) 0 else 1)
		parameters.machineKeyId?.let(writer::fixed)
		writer.fixed(wrappedKey)
		return writer.bytes
	}

	override fun equals(other: Any?) = other is UnlockRecord && parameters == other.parameters && wrappedKey.contentEquals(other.wrappedKey)

	override fun hashCode() = 31 * parameters.hashCode() + wrappedKey.contentHashCode()

	companion object {
		private const val VERSION = 1

		fun decode(bytes: ByteArray): UnlockRecord = try {
			val reader = WireReader(bytes)
			val version = reader.u8()
			if (version != VERSION) throw Unreadable(isNewerVersion = version > VERSION, "version $version")
			val localSalt = reader.take(UnlockParameters.SALT_LENGTH.toLong())
			val argon = Argon2.Parameters(m = reader.u32().toInt(), t = reader.u32().toInt(), p = reader.u32().toInt())
			val machineKeyId = if (reader.bool()) reader.take(MachineKey.ID_LENGTH.toLong()) else null
			val wrappedKey = reader.take(DatabaseKeyWrap.WRAPPED_LENGTH.toLong())
			reader.finish()
			UnlockRecord(UnlockParameters(localSalt, argon, machineKeyId), wrappedKey)
		} catch (failure: WireException) {
			throw Unreadable(isNewerVersion = false, failure.error.name)
		}
	}
}
