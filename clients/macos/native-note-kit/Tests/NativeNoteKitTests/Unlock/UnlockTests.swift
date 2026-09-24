import Foundation
import Testing

@testable import NativeNoteKit

private func seed(_ password: String, in directory: URL) async throws -> UnlockParameters {
	let parameters = try UnlockParameters.fastBoundToThisMac()
	try AppLock.write(parameters, to: AppLock.currentFile(in: directory))
	let store = try await NoteStore.open(
		url: AppLock.databaseFile(in: directory),
		key: try Unlock.localDbKey(password: password, parameters: parameters)
	)
	try await store.save(Note(id: UUID(), body: "seeded", createdAt: Date(), updatedAt: Date()))
	return parameters
}

@Suite(.serialized)
struct UnlockTests {
	@Test func opensWithTheRightPasswordAndRefusesTheWrong() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		_ = try await seed("correct horse", in: directory)

		let opened = try await Unlock.open(password: "correct horse", in: directory)
		#expect(try await opened.liveNotes().map(\.body) == ["seeded"])

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "wrong horse", in: directory)
		}
	}

	@Test func reportsWhenTheAppWasNeverSetUp() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		await #expect(throws: Unlock.Failure.neverSetUp) {
			_ = try await Unlock.open(password: "anything", in: directory)
		}
	}

	@Test func aDifferentSaltProducesADifferentKey() throws {
		let first = try UnlockParameters.fastBoundToThisMac()
		var second = first
		second.localSalt = Data(repeating: 0x99, count: 16)

		#expect(
			try Unlock.localDbKey(password: "same", parameters: first)
				!= Unlock.localDbKey(password: "same", parameters: second)
		)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aDifferentDeviceKeyProducesADifferentKey() throws {
		let mine = try UnlockParameters.fastBoundToThisMac()
		var theirs = mine
		theirs.enclaveKey = try MachineKey().representation

		#expect(
			try Unlock.localDbKey(password: "same", parameters: mine)
				!= Unlock.localDbKey(password: "same", parameters: theirs)
		)
	}

	@Test func changingThePasswordRekeysAndLeavesOneParameterFile() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let store = try await Unlock.open(password: "old password", in: directory)

		try await Unlock.changePassword(
			to: "new password",
			from: parameters,
			store: store,
			in: directory
		)

		let reopened = try await Unlock.open(password: "new password", in: directory)
		#expect(try await reopened.liveNotes().map(\.body) == ["seeded"])
		#expect(AppLock.candidates(in: directory).count == 1)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}

	@Test func survivesACrashBetweenWritingPendingParametersAndRekeying() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)

		var pending = parameters
		pending.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(pending, to: AppLock.pendingRekeyFile(in: directory))

		#expect(AppLock.candidates(in: directory).count == 2)
		let opened = try await Unlock.open(password: "old password", in: directory)
		#expect(try await opened.liveNotes().map(\.body) == ["seeded"])
	}

	@Test func setUpPersistsCalibratedParametersBoundToThisMac() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		_ = try await Unlock.setUp(password: "correct horse", in: directory)

		let candidates = AppLock.candidates(in: directory)
		let stored = try #require(candidates.first)
		#expect(candidates.count == 1)
		#expect(stored.localSalt.count == 16)
		#expect(stored.argon.t == Argon2.floor.t)
		#expect(stored.argon.p == Argon2.floor.p)
		#expect(stored.argon.m >= Argon2.floor.m)
		#expect((stored.enclaveKey != nil) == MachineKey.isAvailable)
		let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
		#expect(mode == 0o700)
		_ = try await Unlock.open(password: "correct horse", in: directory)
	}

	@Test func survivesACrashAfterRekeyingBeforePromoting() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		var pending = parameters
		pending.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(pending, to: AppLock.pendingRekeyFile(in: directory))
		let store = try await Unlock.open(password: "old password", in: directory)

		try await store.rekey(to: try Unlock.localDbKey(password: "new password", parameters: pending))
		await store.close()

		let opened = try await Unlock.open(password: "new password", in: directory)
		#expect(try await opened.liveNotes().map(\.body) == ["seeded"])
		#expect(AppLock.candidates(in: directory).count == 2)
		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}
}
