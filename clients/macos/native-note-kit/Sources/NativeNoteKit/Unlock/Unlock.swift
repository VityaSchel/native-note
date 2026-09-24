import CryptoKit
import Foundation

nonisolated enum Unlock {
	enum Failure: Error, Equatable {
		case neverSetUp
		case wrongPassword
	}

	private static let blockingWork = DispatchQueue(label: "dev.hloth.nativenote.unlock", qos: .userInitiated)

	static func localDbKey(password: String, parameters: UnlockParameters) throws -> Data {
		let argonOut = try Argon2.hash(
			password: Data(password.utf8),
			salt: parameters.localSalt,
			parameters: parameters.argon
		)
		let machineId = try parameters.enclaveKey.map {
			try MachineKey(representation: $0).machineId()
		}
		return KeyDerivation.localDbKey(
			argonOut: argonOut,
			machineId: machineId ?? Data(),
			localSalt: parameters.localSalt
		)
	}

	static func makeParameters() throws -> UnlockParameters {
		UnlockParameters(
			localSalt: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) },
			argon: try Argon2.calibrateMemory(),
			enclaveKey: MachineKey.isAvailable ? try MachineKey().representation : nil
		)
	}

	@concurrent static func setUp(
		password: String,
		in directory: URL,
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = Unlock.makeParameters
	) async throws -> NoteStore {
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let (parameters, key) = try await offThePool {
			let parameters = try makeParameters()
			return (parameters, try localDbKey(password: password, parameters: parameters))
		}
		let store = try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: key)
		try AppLock.write(parameters, to: AppLock.currentFile(in: directory))
		return store
	}

	@concurrent static func open(password: String, in directory: URL) async throws -> NoteStore {
		let candidates = AppLock.candidates(in: directory)
		guard !candidates.isEmpty else { throw Failure.neverSetUp }

		for parameters in candidates {
			do {
				let key = try await offThePool { try localDbKey(password: password, parameters: parameters) }
				return try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: key)
			} catch SQLiteError.wrongKey {
				continue
			}
		}
		throw Failure.wrongPassword
	}

	@concurrent static func changePassword(
		to newPassword: String,
		from parameters: UnlockParameters,
		store: NoteStore,
		in directory: URL
	) async throws {
		var next = parameters
		next.localSalt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
		let newKey = try await offThePool { [next] in try localDbKey(password: newPassword, parameters: next) }

		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))
		try await store.rekey(to: newKey)
		_ = try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: newKey)
		try AppLock.promoteRekey(in: directory)
	}

	private static func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			blockingWork.async { continuation.resume(with: Result(catching: work)) }
		}
	}
}
