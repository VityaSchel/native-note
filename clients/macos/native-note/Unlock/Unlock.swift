import CryptoKit
import Foundation

nonisolated enum Unlock {
	enum Failure: Error, Equatable {
		case neverSetUp
		case wrongPassword
	}

	static func localDbKey(password: String, parameters: UnlockParameters) throws -> Data {
		let argonOut = try Argon2.hash(
			password: Data(password.utf8),
			salt: parameters.localSalt,
			parameters: parameters.argon
		)
		let machineId = try parameters.enclaveKey.map {
			try MachineBinding.machineId(key: MachineKey(representation: $0))
		}
		return KeyDerivation.localDbKey(
			argonOut: argonOut,
			machineId: machineId ?? Data(),
			localSalt: parameters.localSalt
		)
	}

	static func createParameters() throws -> UnlockParameters {
		UnlockParameters(
			localSalt: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) },
			argon: try Argon2.calibrateMemory(),
			enclaveKey: MachineKey.isAvailable ? try MachineKey().representation : nil
		)
	}

	static func setUp(password: String, database: URL, in directory: URL) async throws -> NoteStore {
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let parameters = try createParameters()
		let store = try await NoteStore.open(
			url: database,
			key: try localDbKey(password: password, parameters: parameters)
		)
		try AppLock.write(parameters, to: AppLock.current(in: directory))
		return store
	}

	static func open(password: String, database: URL, in directory: URL) async throws -> NoteStore {
		let candidates = AppLock.candidates(in: directory)
		guard !candidates.isEmpty else { throw Failure.neverSetUp }

		for parameters in candidates {
			do {
				return try await NoteStore.open(
					url: database,
					key: try localDbKey(password: password, parameters: parameters)
				)
			} catch SQLiteError.wrongKey {
				continue
			}
		}
		throw Failure.wrongPassword
	}

	static func changePassword(
		to newPassword: String,
		from parameters: UnlockParameters,
		store: NoteStore,
		database: URL,
		in directory: URL
	) async throws {
		var next = parameters
		next.localSalt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
		let newKey = try localDbKey(password: newPassword, parameters: next)

		try AppLock.write(next, to: AppLock.pendingRekey(in: directory))
		try await store.rekey(to: newKey)
		_ = try await NoteStore.open(url: database, key: newKey)
		try AppLock.promoteRekey(in: directory)
	}
}
