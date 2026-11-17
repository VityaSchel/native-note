import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

private let seededKey = SymmetricKey(data: Data(repeating: 0x5E, count: 32))

private func records(_ directory: URL) -> FileUnlockRecordStore {
	FileUnlockRecordStore(directory: directory)
}

private func seed(_ password: String, in directory: URL) async throws -> UnlockRecord {
	try await makeLibrary(in: directory, password: password, key: seededKey, parameters: try UnlockParameters.fastBoundToThisMac())
	let store = try await NoteStore.open(url: AppLock.databaseFile(in: directory), key: seededKey)
	try await store.save(Note(id: UUID(), body: "seeded", createdAt: Date().epochMilliseconds, updatedAt: Date().epochMilliseconds))
	await store.close()
	return try #require(try records(directory).read())
}

@Suite(.scratch, .serialized)
struct UnlockTests {
	@Test func opensWithTheRightPasswordAndRefusesTheWrong() async throws {
		let directory = temporaryDirectory()
		_ = try await seed("correct horse", in: directory)

		let opened = try await Unlock.open(password: "correct horse", in: directory, records: records(directory))
		#expect(try await opened.store.liveNotes().map(\.body) == ["seeded"])

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "wrong horse", in: directory, records: records(directory))
		}
	}

	@Test func reportsWhenTheAppWasNeverSetUp() async throws {
		let directory = temporaryDirectory()

		await #expect(throws: Unlock.Failure.neverSetUp) {
			_ = try await Unlock.open(password: "anything", in: directory, records: records(directory))
		}
	}

	@Test(arguments: [
		("correct horse", "21106e3337936a6b4e57bb3be316d082d5fce5898d97fab1a498a17f1e9edb67"),
		("пароль ✓", "3a334c2037ef58bb4e8fd48d1049cc2094adde9142a9d3b0187e96f9eb827638"),
		("", "b09534360cf060df49cee48b4f0128f241041ce13c280554ed1c9fc594c7a2de"),
	])
	func aPasswordDerivesTheSameUnlockKeyItAlwaysHas(password: String, hex: String) throws {
		let key = try Unlock.unlockKey(password: password, parameters: .fast)

		#expect(key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } == hex)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func anUnlockKeyBoundToThisMacIsHKDFOverTheArgonOutputThenTheMachineId() throws {
		let parameters = try UnlockParameters.fastBoundToThisMac()
		let argonOut = try Argon2.hash(password: "same", salt: parameters.localSalt, parameters: parameters.argon)
		let machineId = try MachineKey(representation: try #require(parameters.enclaveKey)).machineId()

		let expected = HKDF<SHA256>.deriveKey(
			inputKeyMaterial: SymmetricKey(data: argonOut.withUnsafeBytes { Data($0) } + machineId.withUnsafeBytes { Data($0) }),
			salt: parameters.localSalt,
			info: Data("native-note/unlock/v1".utf8),
			outputByteCount: 32
		)

		#expect(try Unlock.unlockKey(password: "same", parameters: parameters) == expected)
	}

	@Test func setUpWrapsARandomKeyRatherThanOneDerivedFromThePassword() async throws {
		let first = temporaryDirectory()
		let second = temporaryDirectory()

		_ = try await Unlock.setUp(password: "same", in: first, records: records(first), makeParameters: { .fast })
		_ = try await Unlock.setUp(password: "same", in: second, records: records(second), makeParameters: { .fast })

		let firstKey = try Unlock.databaseKey(password: "same", record: try #require(try records(first).read()))
		let secondKey = try Unlock.databaseKey(password: "same", record: try #require(try records(second).read()))
		#expect(firstKey != secondKey)
		#expect(firstKey != (try Unlock.unlockKey(password: "same", parameters: .fast)))
	}

	@Test func provingTheRightPasswordGivesTheKeyThatOpensTheLibrary() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("correct horse", in: directory)

		let key = try await Unlock.provenKey(password: "correct horse", record: record, in: directory)

		#expect(key == seededKey)
	}

	@Test func provingAWrongPasswordSaysSo() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("correct horse", in: directory)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.provenKey(password: "wrong horse", record: record, in: directory)
		}
	}

	@Test func aDatabaseItsRecordDoesNotOpenIsNamed() async throws {
		let directory = temporaryDirectory()
		let other = temporaryDirectory()
		let record = try await seed("correct horse", in: directory)
		try await makeLibrary(in: other, password: "correct horse", key: SymmetricKey(size: .bits256))
		try FileManager.default.removeItem(at: AppLock.databaseFile(in: directory))
		try FileManager.default.copyItem(at: AppLock.databaseFile(in: other), to: AppLock.databaseFile(in: directory))

		await #expect(throws: Unlock.Failure.keyRejected) {
			_ = try await Unlock.open(password: "correct horse", in: directory, records: records(directory))
		}
		await #expect(throws: Unlock.Failure.keyRejected) {
			_ = try await Unlock.provenKey(password: "correct horse", record: record, in: directory)
		}
	}

	@Test func aDifferentSaltProducesADifferentUnlockKey() throws {
		let first = try UnlockParameters.fastBoundToThisMac()
		var second = first
		second.localSalt = Data(repeating: 0x99, count: 16)

		#expect(
			try Unlock.unlockKey(password: "same", parameters: first)
				!= Unlock.unlockKey(password: "same", parameters: second)
		)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aDifferentDeviceKeyProducesADifferentUnlockKey() throws {
		let mine = try UnlockParameters.fastBoundToThisMac()
		var theirs = mine
		theirs.enclaveKey = try MachineKey().representation

		#expect(
			try Unlock.unlockKey(password: "same", parameters: mine)
				!= Unlock.unlockKey(password: "same", parameters: theirs)
		)
	}

	@Test func changingThePasswordRewrapsTheSameKeyAndLeavesTheDatabaseAsItWas() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)
		let database = try Data(contentsOf: AppLock.databaseFile(in: directory))
		let recalibrated = Argon2.Parameters(m: 2048, t: 1, p: 1)

		let changed = try await Unlock.changePassword(
			from: "old password",
			to: "new password",
			record: record,
			in: directory,
			records: records(directory),
			calibrate: { recalibrated }
		)

		#expect(try Data(contentsOf: AppLock.databaseFile(in: directory)) == database)
		#expect(changed == (try records(directory).read()))
		#expect(changed.argon == recalibrated)
		#expect(changed.enclaveKey == record.enclaveKey)
		#expect(changed.localSalt != record.localSalt)
		#expect(try Unlock.databaseKey(password: "new password", record: changed) == seededKey)
		let reopened = try await Unlock.open(password: "new password", in: directory, records: records(directory))
		#expect(try await reopened.store.liveNotes().map(\.body) == ["seeded"])
		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		}
	}

	@Test func aKeySavedForTouchIDStillOpensTheLibraryAfterAPasswordChange() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)

		_ = try await Unlock.changePassword(from: "old password", to: "new password", record: record, in: directory, records: records(directory), calibrate: { UnlockParameters.fast.argon })

		let unlocked = try await Unlock.open(key: seededKey, in: directory, records: records(directory))
		#expect(try await unlocked.store.liveNotes().map(\.body) == ["seeded"])
	}

	@Test func setUpPersistsCalibratedParametersBoundToThisMac() async throws {
		let directory = temporaryDirectory()

		_ = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory))

		let stored = try #require(try records(directory).read())
		#expect(stored.localSalt.count == 16)
		#expect(stored.argon.t == Argon2.floor.t)
		#expect(stored.argon.p == Argon2.floor.p)
		#expect(stored.argon.m >= Argon2.floor.m)
		#expect((stored.enclaveKey != nil) == MachineKey.isAvailable)
		#expect(stored.wrappedKey.count == DatabaseKeyWrap.wrappedLength)
		let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
		#expect(mode == 0o700)
		_ = try await Unlock.open(password: "correct horse", in: directory, records: records(directory))
	}

	@Test func openNeverCreatesTheDatabase() async throws {
		let directory = temporaryDirectory()
		try records(directory).write(.fast)

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(password: "correct horse", in: directory, records: records(directory))
		}
		#expect(!FileManager.default.fileExists(atPath: AppLock.databaseFile(in: directory).path))
	}

	@Test func aDamagedRecordIsReportedRatherThanAWrongPassword() async throws {
		let directory = temporaryDirectory()
		_ = try await seed("old password", in: directory)
		try Data("not a property list".utf8).write(to: AppLock.recordFile(in: directory))

		await #expect(throws: DecodingError.self) {
			_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		}
	}

	@Test func aRecordFromAFutureVersionIsReportedAsSuch() async throws {
		let directory = temporaryDirectory()
		var future = try await seed("old password", in: directory)
		future.version = 2
		try AppLock.durablyReplace(AppLock.recordFile(in: directory), with: UnlockRecords.encode(future))

		await #expect(throws: AppLock.Unreadable.unsupportedVersion(2)) {
			_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		}
	}

	@Test func aKeyFromAnotherMacIsNamed() async throws {
		let directory = temporaryDirectory()
		var foreign = try await seed("old password", in: directory)
		foreign.enclaveKey = Data(repeating: 0x11, count: 8)
		try records(directory).write(foreign)

		await #expect(throws: Unlock.Failure.boundToAnotherMac) {
			_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		}
	}

	@Test func setUpAfterACrashSetsTheOrphanedDatabaseAside() async throws {
		let directory = temporaryDirectory()
		let orphan = try await openStore(at: AppLock.databaseFile(in: directory))
		try await orphan.save(sampleNote(body: "typed before the crash"))

		let unlocked = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory), makeParameters: { .fast })

		#expect(try await unlocked.store.liveNotes().isEmpty)
		let asides = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("notes-set-aside-") }
		let aside = try #require(asides.first { $0.hasSuffix(".db") })
		#expect(asides.contains(aside + "-wal"))
		await orphan.close()
		let kept = try await NoteStore.open(url: directory.appending(path: aside), key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test func setUpRefusesToReplaceAnExistingRecord() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)

		await #expect(throws: Unlock.Failure.alreadySetUp) {
			_ = try await Unlock.setUp(password: "another", in: directory, records: records(directory), makeParameters: { .fast })
		}
		#expect(try records(directory).read() == record)
		_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
	}

	@Test func changingThePasswordNeverLowersTheMemoryCost() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)
		let weaker = Argon2.Parameters(m: record.argon.m / 2, t: record.argon.t, p: record.argon.p)

		let changed = try await Unlock.changePassword(from: "old password", to: "new password", record: record, in: directory, records: records(directory), calibrate: { weaker })

		#expect(changed.argon == record.argon)
		_ = try await Unlock.open(password: "new password", in: directory, records: records(directory))
	}

	@Test func changingThePasswordRefusesAWrongCurrentPasswordAndWritesNothing() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)

		await #expect(throws: Unlock.Failure.wrongPassword) {
			try await Unlock.changePassword(from: "guess", to: "new password", record: record, in: directory, records: records(directory), calibrate: { UnlockParameters.fast.argon })
		}
		#expect(try records(directory).read() == record)
		_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
	}

	@Test func aPasswordChangeThatCannotWriteItsRecordKeepsTheOldPassword() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
		let record = try await seed("old password", in: directory)
		try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

		await #expect(throws: (any Error).self) {
			try await Unlock.changePassword(from: "old password", to: "new password", record: record, in: directory, records: records(directory), calibrate: { UnlockParameters.fast.argon })
		}

		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		#expect(try records(directory).read() == record)
		_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		await #expect(throws: Unlock.Failure.wrongPassword) {
			_ = try await Unlock.open(password: "new password", in: directory, records: records(directory))
		}
	}

	@Test func anEmptyDatabaseFileIsReportedMissing() async throws {
		let directory = temporaryDirectory()
		try records(directory).write(.fast)
		let database = AppLock.databaseFile(in: directory)
		FileManager.default.createFile(atPath: database.path, contents: Data())

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(password: "correct horse", in: directory, records: records(directory))
		}
		#expect(try FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int == 0)
	}

	@Test func aSetUpThatCannotCreateTheDatabaseLeavesNoRecord() async throws {
		let directory = temporaryDirectory()
		let database = AppLock.databaseFile(in: directory)

		await #expect(throws: SQLiteError.self) {
			_ = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory), makeParameters: {
				try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
				return .fast
			})
		}
		#expect(try records(directory).read() == nil)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aKeyThatLoadsButCannotDeriveIsNamed() async throws {
		let directory = temporaryDirectory()
		var damaged = try await seed("old password", in: directory)
		var blob = try #require(damaged.enclaveKey)
		blob[blob.count - 1] ^= 0xff
		damaged.enclaveKey = blob
		try records(directory).write(damaged)

		await #expect(throws: Unlock.Failure.boundToAnotherMac) {
			_ = try await Unlock.open(password: "old password", in: directory, records: records(directory))
		}
	}

	@Test(arguments: 0 ... 2)
	func setUpFinishesASetAsideACrashInterrupted(movedBeforeTheCrash: Int) async throws {
		let directory = temporaryDirectory()
		let live = temporaryDirectory()
		let running = try await openStore(at: AppLock.databaseFile(in: live))
		try await running.save(sampleNote(body: "typed before the crash"))
		try FileManager.default.copyItem(at: live, to: directory)
		await running.close()
		let database = AppLock.databaseFile(in: directory)
		let aside = try AppLock.asideFile(for: database)
		for suffix in ["-wal", "-shm", ""].prefix(movedBeforeTheCrash) {
			try FileManager.default.moveItem(atPath: database.path + suffix, toPath: aside.path + suffix)
		}

		_ = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory), makeParameters: { .fast })

		let kept = try await NoteStore.open(url: aside, key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test(arguments: ["-wal", "-shm", ""])
	func aSetAsideThatFailsHalfWayFinishesOnTheNextSetUp(blockedSuffix: String) async throws {
		let directory = temporaryDirectory()
		let live = temporaryDirectory()
		let running = try await openStore(at: AppLock.databaseFile(in: live))
		try await running.save(sampleNote(body: "typed before the crash"))
		try FileManager.default.copyItem(at: live, to: directory)
		await running.close()
		let aside = try AppLock.asideFile(for: AppLock.databaseFile(in: directory))
		let blocker = URL(fileURLWithPath: aside.path + blockedSuffix)
		try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)

		await #expect(throws: (any Error).self) {
			_ = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory), makeParameters: { .fast })
		}
		try FileManager.default.removeItem(at: blocker)
		_ = try await Unlock.setUp(password: "correct horse", in: directory, records: records(directory), makeParameters: { .fast })

		let kept = try await NoteStore.open(url: aside, key: databaseKey)
		#expect(try await kept.liveNotes().map(\.body) == ["typed before the crash"])
	}

	@Test func aStoredKeyOpensTheLibraryAndReportsItsRecord() async throws {
		let directory = temporaryDirectory()
		let record = try await seed("old password", in: directory)

		let unlocked = try await Unlock.open(key: seededKey, in: directory, records: records(directory))

		#expect(try await unlocked.store.liveNotes().map(\.body) == ["seeded"])
		#expect(unlocked.record == record)
	}

	@Test func aStoredKeyThatNoLongerFitsIsRejected() async throws {
		let directory = temporaryDirectory()
		_ = try await seed("old password", in: directory)

		await #expect(throws: Unlock.Failure.storedKeyRejected) {
			_ = try await Unlock.open(key: SymmetricKey(data: Data(repeating: 0x42, count: 32)), in: directory, records: records(directory))
		}
	}

	@Test func aStoredKeyNeverCreatesTheDatabase() async throws {
		let directory = temporaryDirectory()
		try records(directory).write(.fast)

		await #expect(throws: Unlock.Failure.databaseMissing) {
			_ = try await Unlock.open(key: SymmetricKey(data: Data(repeating: 0x42, count: 32)), in: directory, records: records(directory))
		}
		#expect(!FileManager.default.fileExists(atPath: AppLock.databaseFile(in: directory).path))
		let elsewhere = temporaryDirectory()
		await #expect(throws: Unlock.Failure.neverSetUp) {
			_ = try await Unlock.open(key: SymmetricKey(data: Data(repeating: 0x42, count: 32)), in: elsewhere, records: records(elsewhere))
		}
	}

	@Test func aStoredKeyOnANewerDatabaseSaysSoRatherThanRejectingTheKey() async throws {
		let directory = temporaryDirectory()
		_ = try await seed("old password", in: directory)
		try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: seededKey).execute("PRAGMA user_version = 99")

		await #expect(throws: SQLiteError.self) {
			_ = try await Unlock.open(key: seededKey, in: directory, records: records(directory))
		}
	}
}
