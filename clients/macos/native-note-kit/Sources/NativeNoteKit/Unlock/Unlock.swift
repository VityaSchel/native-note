import CryptoKit
import Foundation

nonisolated enum Unlock {
	enum Failure: Error, Equatable {
		case neverSetUp
		case alreadySetUp
		case wrongPassword
		case databaseMissing
		case boundToAnotherMac
		case passwordNotChanged
		case storedKeyRejected
		case keyRejected
	}

	struct Unlocked {
		let store: NoteStore
		let record: UnlockRecord
	}

	static func unlockKey(password: String, parameters: UnlockParameters) throws -> SymmetricKey {
		let argonOut = try Argon2.hash(password: password, salt: parameters.localSalt, parameters: parameters.argon)
		let machineId = try parameters.enclaveKey.map { representation in
			do {
				return try MachineKey(representation: representation).machineId()
			} catch {
				throw Failure.boundToAnotherMac
			}
		}
		return KeyDerivation.unlockKey(argonOut: argonOut, machineId: machineId, localSalt: parameters.localSalt)
	}

	static func databaseKey(password: String, record: UnlockRecord) throws -> SymmetricKey {
		let unlockKey = try unlockKey(password: password, parameters: record.parameters)
		guard let key = DatabaseKeyWrap.unwrap(record.wrappedKey, under: unlockKey) else { throw Failure.wrongPassword }
		return key
	}

	@concurrent static func provenKey(password: String, record: UnlockRecord, in directory: URL) async throws -> SymmetricKey {
		let key = try await BlockingWork.run { try databaseKey(password: password, record: record) }
		do {
			_ = try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: key)
		} catch SQLiteError.wrongKey {
			throw Failure.keyRejected
		}
		return key
	}

	static func makeParameters() throws -> UnlockParameters {
		UnlockParameters(
			localSalt: Data.random(.bits128),
			argon: try Argon2.calibrateMemory(),
			enclaveKey: MachineKey.isAvailable ? try MachineKey().representation : nil
		)
	}

	static func makeRecord(password: String, key: SymmetricKey, parameters: UnlockParameters) throws -> UnlockRecord {
		let unlockKey = try unlockKey(password: password, parameters: parameters)
		let record = UnlockRecord(parameters: parameters, wrappedKey: try DatabaseKeyWrap.wrap(key, under: unlockKey))
		guard DatabaseKeyWrap.unwrap(record.wrappedKey, under: unlockKey) == key else { throw Failure.passwordNotChanged }
		return record
	}

	@concurrent static func setUp(
		password: String,
		in directory: URL,
		records: any UnlockRecordStore,
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.makeParameters
	) async throws -> Unlocked {
		guard try records.read() == nil else { throw Failure.alreadySetUp }
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let database = AppLock.databaseFile(in: directory)
		try AppLock.setAside(database)
		let key = SymmetricKey(size: .bits256)
		let record = try await BlockingWork.run { try makeRecord(password: password, key: key, parameters: makeParameters()) }
		let store = try await NoteStore.create(url: database, key: key)
		try records.write(record)
		return Unlocked(store: store, record: record)
	}

	@concurrent static func open(password: String, in directory: URL, records: any UnlockRecordStore) async throws -> Unlocked {
		let (database, record) = try existingLibrary(in: directory, records: records)
		let key = try await BlockingWork.run { try databaseKey(password: password, record: record) }
		do {
			return Unlocked(store: try await NoteStore.open(url: database, key: key), record: record)
		} catch SQLiteError.wrongKey {
			throw Failure.keyRejected
		}
	}

	@concurrent static func open(key: SymmetricKey, in directory: URL, records: any UnlockRecordStore) async throws -> Unlocked {
		let (database, record) = try existingLibrary(in: directory, records: records)
		do {
			return Unlocked(store: try await NoteStore.open(url: database, key: key), record: record)
		} catch SQLiteError.wrongKey {
			throw Failure.storedKeyRejected
		}
	}

	private static func existingLibrary(in directory: URL, records: any UnlockRecordStore) throws -> (database: URL, record: UnlockRecord) {
		guard let record = try records.read() else { throw Failure.neverSetUp }
		let database = AppLock.databaseFile(in: directory)
		let size = (try? FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int) ?? 0
		guard size > 0 else { throw Failure.databaseMissing }
		return (database, record)
	}

	@concurrent static func changePassword(
		from oldPassword: String,
		to newPassword: String,
		record: UnlockRecord,
		in directory: URL,
		records: any UnlockRecordStore,
		calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { try Argon2.calibrateMemory() }
	) async throws -> UnlockRecord {
		let key = try await provenKey(password: oldPassword, record: record, in: directory)
		var next = record.parameters
		next.localSalt = Data.random(.bits128)
		let calibrated = try await BlockingWork.run(calibrate)
		next.argon = calibrated.m > record.argon.m ? calibrated : record.argon
		let changed = try await BlockingWork.run { [next] in try makeRecord(password: newPassword, key: key, parameters: next) }
		guard !Task.isCancelled else { throw Failure.passwordNotChanged }
		try records.write(changed)
		return changed
	}
}
