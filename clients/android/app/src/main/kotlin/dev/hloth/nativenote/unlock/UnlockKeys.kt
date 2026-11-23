package dev.hloth.nativenote.unlock

import dev.hloth.nativenote.crypto.AesGcm
import dev.hloth.nativenote.crypto.Argon2
import dev.hloth.nativenote.crypto.Argon2Calibration
import dev.hloth.nativenote.crypto.DatabaseKeyWrap
import dev.hloth.nativenote.crypto.KeyDerivation
import dev.hloth.nativenote.crypto.MachineKey

object UnlockKeys {
	class WrongPassword : Exception("the password does not open the unlock record")

	class RecordNotProven : Exception("the new unlock record does not unwrap its own key")

	fun makeParameters(strongBox: Boolean, calibrate: () -> Argon2.Parameters = { Argon2Calibration.calibrateMemory() }): UnlockParameters {
		val machineKey = MachineKey.create(strongBox)
		val hardwareBacked = machineKey.takeIf { it.isHardwareBacked } ?: run {
			machineKey.delete()
			null
		}
		return UnlockParameters(AesGcm.randomBytes(UnlockParameters.SALT_LENGTH), calibrate(), hardwareBacked?.id)
	}

	fun unlockKey(password: String, parameters: UnlockParameters): ByteArray {
		val argonOut = Argon2.hash(password, parameters.localSalt, parameters.argon)
		val machineId = try {
			parameters.machineKeyId?.let { MachineKey.load(it).machineId() }
		} catch (failure: Exception) {
			argonOut.fill(0)
			throw failure
		}
		try {
			return KeyDerivation.unlockKey(argonOut, machineId, parameters.localSalt)
		} finally {
			argonOut.fill(0)
			machineId?.fill(0)
		}
	}

	fun databaseKey(password: String, record: UnlockRecord): ByteArray {
		val unlockKey = unlockKey(password, record.parameters)
		try {
			return DatabaseKeyWrap.unwrap(record.wrappedKey, unlockKey) ?: throw WrongPassword()
		} finally {
			unlockKey.fill(0)
		}
	}

	fun makeRecord(password: String, key: ByteArray, parameters: UnlockParameters): UnlockRecord {
		val unlockKey = unlockKey(password, parameters)
		try {
			val record = UnlockRecord(parameters, DatabaseKeyWrap.wrap(key, unlockKey))
			val unwrapped = DatabaseKeyWrap.unwrap(record.wrappedKey, unlockKey)
			val proven = unwrapped?.contentEquals(key) == true
			unwrapped?.fill(0)
			if (!proven) throw RecordNotProven()
			return record
		} finally {
			unlockKey.fill(0)
		}
	}
}
