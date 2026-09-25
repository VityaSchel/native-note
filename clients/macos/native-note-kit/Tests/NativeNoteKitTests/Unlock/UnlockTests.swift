import Foundation
import Testing

@testable import NativeNoteKit

private func seed(_ password: String, in directory: URL) async throws -> UnlockParameters {
	let parameters = try UnlockParameters.fastBoundToThisMac()
	try AppLock.write(parameters, to: AppLock.currentFile(in: directory))
	let store = try await NoteStore.create(
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
		#expect(try await opened.store.liveNotes().map(\.body) == ["seeded"])

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
		let opened = try await Unlock.open(password: "old password", in: directory)

		let recalibrated = Argon2.Parameters(m: 2048, t: 1, p: 1)

		try await Unlock.changePassword(
			from: "old password",
			to: "new password",
			parameters: parameters,
			store: opened.store,
			in: directory,
			calibrate: { recalibrated }
		)

		let reopened = try await Unlock.open(password: "new password", in: directory)
		#expect(try await reopened.store.liveNotes().map(\.body) == ["seeded"])
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		let current = try AppLock.read(from: AppLock.currentFile(in: directory))
		#expect(current.argon == recalibrated)
		#expect(current.enclaveKey == parameters.enclaveKey)

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

		#expect(AppLock.parameterFiles(in: directory).count == 2)
		let opened = try await Unlock.open(password: "old password", in: directory)
		#expect(try await opened.store.liveNotes().map(\.body) == ["seeded"])
		#expect(opened.parameters == parameters)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
	}

	@Test func setUpPersistsCalibratedParametersBoundToThisMac() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }

		_ = try await Unlock.setUp(password: "correct horse", in: directory)

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		let stored = try AppLock.read(from: AppLock.currentFile(in: directory))
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
		let store = try await Unlock.open(password: "old password", in: directory).store
		try AppLock.write(pending, to: AppLock.pendingRekeyFile(in: directory))

		#expect(try await store.rekey(
			from: try Unlock.localDbKey(password: "old password", parameters: parameters),
			to: try Unlock.localDbKey(password: "new password", parameters: pending)
		))
		await store.close()

		let opened = try await Unlock.open(password: "new password", in: directory)
		#expect(try await opened.store.liveNotes().map(\.body) == ["seeded"])
		#expect(opened.parameters == pending)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == pending)
		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}

	@Test func openNeverCreatesTheDatabase() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(password: "correct horse", in: directory)
		}
		#expect(!FileManager.default.fileExists(atPath: AppLock.databaseFile(in: directory).path))
	}

	@Test func aDamagedParameterFileIsReportedRatherThanAWrongPassword() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		_ = try await seed("old password", in: directory)
		try Data("not a property list".utf8).write(to: AppLock.pendingRekeyFile(in: directory))

		await #expect(throws: DecodingError.self) {
			_ = try await Unlock.open(password: "new password", in: directory)
		}
		_ = try await Unlock.open(password: "old password", in: directory)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
	}

	@Test func parametersFromAFutureVersionAreReportedAsSuch() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var future = try await seed("old password", in: directory)
		future.version = 2
		try AppLock.write(future, to: AppLock.currentFile(in: directory))

		await #expect(throws: AppLock.Unreadable.unsupportedVersion(2)) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}

	@Test func aKeyFromAnotherMacIsNamed() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var foreign = try await seed("old password", in: directory)
		foreign.enclaveKey = Data(repeating: 0x11, count: 8)
		try AppLock.write(foreign, to: AppLock.currentFile(in: directory))

		await #expect(throws: Unlock.Failure.boundToAnotherMac) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}

	@Test func setUpAfterACrashSetsTheOrphanedDatabaseAside() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let orphan = try await openStore(at: AppLock.databaseFile(in: directory))
		try await orphan.save(sampleNote(body: "typed before the crash"))

		let unlocked = try await Unlock.setUp(password: "correct horse", in: directory, makeParameters: { .fast })

		#expect(try await unlocked.store.liveNotes().isEmpty)
		let asides = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("notes-set-aside-") }
		let aside = try #require(asides.first { $0.hasSuffix(".db") })
		#expect(asides.contains(aside + "-wal"))
		await orphan.close()
		let kept = try await NoteStore.open(url: directory.appending(path: aside), key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test func setUpRefusesToReplaceExistingParameters() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)

		await #expect(throws: Unlock.Failure.alreadySetUp) {
			_ = try await Unlock.setUp(password: "another", in: directory, makeParameters: { .fast })
		}
		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == parameters)
		_ = try await Unlock.open(password: "old password", in: directory)
	}

	@Test func changingThePasswordNeverLowersTheMemoryCost() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let weaker = Argon2.Parameters(m: parameters.argon.m / 2, t: parameters.argon.t, p: parameters.argon.p)

		try await Unlock.changePassword(from: "old password", to: "new password", parameters: parameters, store: opened.store, in: directory, calibrate: { weaker })

		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)).argon == parameters.argon)
		_ = try await Unlock.open(password: "new password", in: directory)
	}

	@Test func changingThePasswordRefusesAWrongCurrentPassword() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			try await Unlock.changePassword(from: "guess", to: "new password", parameters: parameters, store: opened.store, in: directory, calibrate: { UnlockParameters.fast.argon })
		}
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		_ = try await Unlock.open(password: "old password", in: directory)
	}

	@Test func aRekeyThatDoesNotTakeKeepsTheOldPassword() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let writer = try SQLiteConnection(
			url: AppLock.databaseFile(in: directory),
			rawKey: try Unlock.localDbKey(password: "old password", parameters: parameters)
		)
		try writer.execute("BEGIN IMMEDIATE")

		await #expect(throws: Unlock.Failure.passwordNotChanged) {
			try await Unlock.changePassword(from: "old password", to: "new password", parameters: parameters, store: opened.store, in: directory, calibrate: { UnlockParameters.fast.argon })
		}
		try writer.execute("ROLLBACK")
		try await opened.store.save(sampleNote(body: "typed after"))
		await opened.store.close()

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		let reopened = try await Unlock.open(password: "old password", in: directory)
		#expect(try await reopened.store.liveNotes().map(\.body).sorted() == ["seeded", "typed after"])
		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "new password", in: directory)
		}
	}

	@Test func anEmptyDatabaseFileIsReportedMissing() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		let database = AppLock.databaseFile(in: directory)
		FileManager.default.createFile(atPath: database.path, contents: Data())

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(password: "correct horse", in: directory)
		}
		#expect(try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int == 0)
	}

	@Test func aSetUpThatCannotCreateTheDatabaseLeavesNoParameters() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let database = AppLock.databaseFile(in: directory)

		await #expect(throws: SQLiteError.self) {
			_ = try await Unlock.setUp(password: "correct horse", in: directory, makeParameters: {
				try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
				return .fast
			})
		}
		#expect(AppLock.parameterFiles(in: directory).isEmpty)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aKeyThatLoadsButCannotDeriveIsNamed() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var damaged = try await seed("old password", in: directory)
		var blob = try #require(damaged.enclaveKey)
		blob[blob.count - 1] ^= 0xff
		damaged.enclaveKey = blob
		try AppLock.write(damaged, to: AppLock.currentFile(in: directory))

		await #expect(throws: Unlock.Failure.boundToAnotherMac) {
			_ = try await Unlock.open(password: "old password", in: directory)
		}
	}

	@Test(arguments: 0 ... 2)
	func setUpFinishesASetAsideACrashInterrupted(movedBeforeTheCrash: Int) async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let live = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: live) }
		let running = try await openStore(at: AppLock.databaseFile(in: live))
		try await running.save(sampleNote(body: "typed before the crash"))
		try FileManager.default.copyItem(at: live, to: directory)
		await running.close()
		let database = AppLock.databaseFile(in: directory)
		let aside = try AppLock.asideFile(for: database)
		for suffix in ["-wal", "-shm", ""].prefix(movedBeforeTheCrash) {
			try FileManager.default.moveItem(atPath: database.path + suffix, toPath: aside.path + suffix)
		}

		_ = try await Unlock.setUp(password: "correct horse", in: directory, makeParameters: { .fast })

		let kept = try await NoteStore.open(url: aside, key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test(arguments: ["-wal", "-shm", ""])
	func aSetAsideThatFailsHalfWayFinishesOnTheNextSetUp(blockedSuffix: String) async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let live = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: live) }
		let running = try await openStore(at: AppLock.databaseFile(in: live))
		try await running.save(sampleNote(body: "typed before the crash"))
		try FileManager.default.copyItem(at: live, to: directory)
		await running.close()
		let aside = try AppLock.asideFile(for: AppLock.databaseFile(in: directory))
		let blocker = URL(fileURLWithPath: aside.path + blockedSuffix)
		try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)

		await #expect(throws: (any Error).self) {
			_ = try await Unlock.setUp(password: "correct horse", in: directory, makeParameters: { .fast })
		}
		try FileManager.default.removeItem(at: blocker)
		_ = try await Unlock.setUp(password: "correct horse", in: directory, makeParameters: { .fast })

		let kept = try await NoteStore.open(url: aside, key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test func aStoredKeyOpensTheLibraryAndReportsItsParameters() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let key = try Unlock.localDbKey(password: "old password", parameters: parameters)

		let unlocked = try await Unlock.open(key: key, in: directory)

		#expect(try await unlocked.store.liveNotes().map(\.body) == ["seeded"])
		#expect(unlocked.parameters == parameters)
		#expect(unlocked.key == key)
	}

	@Test func aStoredKeyThatNoLongerFitsIsRejected() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		_ = try await seed("old password", in: directory)

		await #expect(throws: Unlock.Failure.storedKeyRejected) {
			_ = try await Unlock.open(key: Data(repeating: 0x42, count: 32), in: directory)
		}
	}

	@Test func aStoredKeyNeverCreatesTheDatabase() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(key: Data(repeating: 0x42, count: 32), in: directory)
		}
		#expect(!FileManager.default.fileExists(atPath: AppLock.databaseFile(in: directory).path))
		await #expect(throws: Unlock.Failure.neverSetUp) {
			_ = try await Unlock.open(key: Data(repeating: 0x42, count: 32), in: temporaryDirectory())
		}
	}

	@Test func changingThePasswordForgetsTheKeySavedForTouchID() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let keys = FakeKeyStore()
		try keys.save(opened.key)

		try await Unlock.changePassword(from: "old password", to: "new password", parameters: parameters, store: opened.store, in: directory, storedKey: keys, calibrate: { UnlockParameters.fast.argon })

		#expect(keys.storedKey == nil)
	}

	@Test func aPasswordChangeThatDidNotTakeKeepsTheKeySavedForTouchID() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let keys = FakeKeyStore()
		try keys.save(opened.key)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			try await Unlock.changePassword(from: "guess", to: "new password", parameters: parameters, store: opened.store, in: directory, storedKey: keys, calibrate: { UnlockParameters.fast.argon })
		}

		#expect(keys.storedKey == opened.key)
	}

	@Test func aStoredKeyOnANewerDatabaseSaysSoRatherThanRejectingTheKey() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let key = try Unlock.localDbKey(password: "old password", parameters: parameters)
		try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: key).execute("PRAGMA user_version = 99")

		await #expect(throws: SQLiteError.self) {
			_ = try await Unlock.open(key: key, in: directory)
		}
	}

	@Test func aStoredKeyReportsTheCurrentParametersWhenARekeyIsPending() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		var pending = parameters
		pending.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(pending, to: AppLock.pendingRekeyFile(in: directory))

		let unlocked = try await Unlock.open(key: try Unlock.localDbKey(password: "old password", parameters: parameters), in: directory)

		#expect(unlocked.parameters == parameters)
	}

	@Test func aPasswordChangeThatDoesNotTakeKeepsTheKeySavedForTouchID() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let keys = FakeKeyStore()
		try keys.save(opened.key)
		let writer = try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: opened.key)
		try writer.execute("BEGIN IMMEDIATE")

		await #expect(throws: Unlock.Failure.passwordNotChanged) {
			try await Unlock.changePassword(from: "old password", to: "new password", parameters: parameters, store: opened.store, in: directory, storedKey: keys, calibrate: { UnlockParameters.fast.argon })
		}
		try writer.execute("ROLLBACK")

		#expect(keys.storedKey == opened.key)
	}

	@Test func aPasswordChangeThatCannotPromoteStillForgetsTheOldKey() async throws {
		let directory = temporaryDirectory()
		let current = AppLock.currentFile(in: directory)
		defer {
			try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: current.path)
			try? FileManager.default.removeItem(at: directory)
		}
		let parameters = try await seed("old password", in: directory)
		let opened = try await Unlock.open(password: "old password", in: directory)
		let keys = FakeKeyStore()
		try keys.save(opened.key)
		try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: current.path)

		await #expect(throws: (any Error).self) {
			try await Unlock.changePassword(from: "old password", to: "new password", parameters: parameters, store: opened.store, in: directory, storedKey: keys, calibrate: { UnlockParameters.fast.argon })
		}

		#expect(keys.storedKey == nil)
	}
}
