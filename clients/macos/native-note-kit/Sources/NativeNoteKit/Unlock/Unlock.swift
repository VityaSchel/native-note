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
	}

	struct Unlocked {
		let store: NoteStore
		let parameters: UnlockParameters
	}

	private static let blockingWork = DispatchQueue(label: "dev.hloth.nativenote.unlock", qos: .userInitiated)

	static func localDbKey(password: String, parameters: UnlockParameters) throws -> Data {
		let argonOut = try Argon2.hash(
			password: Data(password.utf8),
			salt: parameters.localSalt,
			parameters: parameters.argon
		)
		let machineId = try parameters.enclaveKey.map { representation in
			do {
				return try MachineKey(representation: representation).machineId()
			} catch {
				throw Failure.boundToAnotherMac
			}
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
	) async throws -> Unlocked {
		guard AppLock.parameterFiles(in: directory).isEmpty else { throw Failure.alreadySetUp }
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		let database = AppLock.databaseFile(in: directory)
		try AppLock.setAside(database)
		let (parameters, key) = try await offThePool {
			let parameters = try makeParameters()
			return (parameters, try localDbKey(password: password, parameters: parameters))
		}
		let store = try await NoteStore.create(url: database, key: key)
		try AppLock.write(parameters, to: AppLock.currentFile(in: directory))
		return Unlocked(store: store, parameters: parameters)
	}

	@concurrent static func open(password: String, in directory: URL) async throws -> Unlocked {
		let files = AppLock.parameterFiles(in: directory)
		guard !files.isEmpty else { throw Failure.neverSetUp }
		let database = AppLock.databaseFile(in: directory)
		let size = (try? FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int) ?? 0
		guard size > 0 else { throw Failure.databaseMissing }

		var unreadable: Error?
		for file in files {
			let parameters: UnlockParameters
			do {
				parameters = try AppLock.read(from: file)
			} catch {
				unreadable = unreadable ?? error
				continue
			}
			do {
				let key = try await offThePool { try localDbKey(password: password, parameters: parameters) }
				let store = try await NoteStore.open(url: database, key: key)
				try AppLock.keep(file, in: directory)
				return Unlocked(store: store, parameters: parameters)
			} catch SQLiteError.wrongKey {
				continue
			}
		}
		throw unreadable ?? Failure.wrongPassword
	}

	@concurrent static func changePassword(
		from oldPassword: String,
		to newPassword: String,
		parameters: UnlockParameters,
		store: NoteStore,
		in directory: URL
	) async throws {
		let database = AppLock.databaseFile(in: directory)
		let oldKey = try await offThePool { try localDbKey(password: oldPassword, parameters: parameters) }
		do {
			_ = try await NoteStore.open(url: database, key: oldKey)
		} catch SQLiteError.wrongKey {
			throw Failure.wrongPassword
		}

		var next = parameters
		next.localSalt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
		let newKey = try await offThePool { [next] in try localDbKey(password: newPassword, parameters: next) }

		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))
		guard try await store.rekey(from: oldKey, to: newKey) else {
			try FileManager.default.removeItem(at: AppLock.pendingRekeyFile(in: directory))
			throw Failure.passwordNotChanged
		}
		try AppLock.promoteRekey(in: directory)
	}

	private static func offThePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			blockingWork.async { continuation.resume(with: Result(catching: work)) }
		}
	}
}
