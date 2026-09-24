import Foundation
import Testing

@testable import NativeNoteKit

private func fastParameters() throws -> UnlockParameters {
	UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.Parameters(m: 1024, t: 1, p: 1),
		enclaveKey: MachineKey.isAvailable ? try MachineKey().representation : nil
	)
}

private func workspace() -> (directory: URL, database: URL) {
	let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
	return (directory, directory.appending(path: "notes.db"))
}

private func seed(_ password: String, in place: (directory: URL, database: URL)) async throws -> UnlockParameters {
	let parameters = try fastParameters()
	try AppLock.write(parameters, to: AppLock.current(in: place.directory))
	let store = try await NoteStore.open(
		url: place.database,
		key: try Unlock.localDbKey(password: password, parameters: parameters)
	)
	try await store.save(Note(id: UUID(), body: "seeded", createdAt: Date(), updatedAt: Date()))
	return parameters
}

@Suite(.serialized)
struct UnlockTests {
	@Test func opensWithTheRightPasswordAndRefusesTheWrong() async throws {
		let place = workspace()
		defer { try? FileManager.default.removeItem(at: place.directory) }
		_ = try await seed("correct horse", in: place)

		let opened = try await Unlock.open(password: "correct horse", database: place.database, in: place.directory)
		#expect(try await opened.liveNotes().map(\.body) == ["seeded"])

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "wrong horse", database: place.database, in: place.directory)
		}
	}

	@Test func reportsWhenTheAppWasNeverSetUp() async throws {
		let place = workspace()
		defer { try? FileManager.default.removeItem(at: place.directory) }

		await #expect(throws: Unlock.Failure.neverSetUp) {
			_ = try await Unlock.open(password: "anything", database: place.database, in: place.directory)
		}
	}

	@Test func aDifferentSaltProducesADifferentKey() throws {
		var first = try fastParameters()
		var second = first
		second.localSalt = Data(repeating: 0x99, count: 16)
		first.argon = Argon2.Parameters(m: 1024, t: 1, p: 1)

		#expect(
			try Unlock.localDbKey(password: "same", parameters: first)
				!= Unlock.localDbKey(password: "same", parameters: second)
		)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aDifferentDeviceKeyProducesADifferentKey() throws {
		var mine = try fastParameters()
		var theirs = mine
		theirs.enclaveKey = try MachineKey().representation
		mine.argon = Argon2.Parameters(m: 1024, t: 1, p: 1)

		#expect(
			try Unlock.localDbKey(password: "same", parameters: mine)
				!= Unlock.localDbKey(password: "same", parameters: theirs)
		)
	}

	@Test func changingThePasswordRekeysAndLeavesOneParameterFile() async throws {
		let place = workspace()
		defer { try? FileManager.default.removeItem(at: place.directory) }
		let parameters = try await seed("old password", in: place)
		let store = try await Unlock.open(password: "old password", database: place.database, in: place.directory)

		try await Unlock.changePassword(
			to: "new password",
			from: parameters,
			store: store,
			database: place.database,
			in: place.directory
		)

		let reopened = try await Unlock.open(password: "new password", database: place.database, in: place.directory)
		#expect(try await reopened.liveNotes().map(\.body) == ["seeded"])
		#expect(AppLock.candidates(in: place.directory).count == 1)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "old password", database: place.database, in: place.directory)
		}
	}

	@Test func survivesACrashBetweenWritingPendingParametersAndRekeying() async throws {
		let place = workspace()
		defer { try? FileManager.default.removeItem(at: place.directory) }
		let parameters = try await seed("old password", in: place)

		var pending = parameters
		pending.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(pending, to: AppLock.pendingRekey(in: place.directory))

		#expect(AppLock.candidates(in: place.directory).count == 2)
		let opened = try await Unlock.open(password: "old password", database: place.database, in: place.directory)
		#expect(try await opened.liveNotes().map(\.body) == ["seeded"])
	}

	@Test func setUpPersistsCalibratedParametersBoundToThisMac() async throws {
		let place = workspace()
		defer { try? FileManager.default.removeItem(at: place.directory) }

		_ = try await Unlock.setUp(password: "correct horse", database: place.database, in: place.directory)

		let candidates = AppLock.candidates(in: place.directory)
		let stored = try #require(candidates.first)
		#expect(candidates.count == 1)
		#expect(stored.localSalt.count == 16)
		#expect(stored.argon.t == Argon2.floor.t)
		#expect(stored.argon.p == Argon2.floor.p)
		#expect(stored.argon.m >= Argon2.floor.m)
		#expect((stored.enclaveKey != nil) == MachineKey.isAvailable)
		let mode = try FileManager.default.attributesOfItem(atPath: place.directory.path)[.posixPermissions] as? Int
		#expect(mode == 0o700)
		_ = try await Unlock.open(password: "correct horse", database: place.database, in: place.directory)
	}
}
