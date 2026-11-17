import Foundation
import Testing

@testable import NativeNoteKit

private extension Gate {
	func holdCalibration() -> Argon2.Parameters {
		hold()
		return UnlockParameters.fast.argon
	}
}

private struct GatedRecords: UnlockRecordStore {
	let records: FileUnlockRecordStore
	let gate: Gate

	func read() throws -> UnlockRecord? { try records.read() }

	func write(_ record: UnlockRecord) throws {
		gate.hold()
		try records.write(record)
	}

	func delete() throws { try records.delete() }
}

private func recordBytes(in directory: URL) throws -> Data {
	try Data(contentsOf: AppLock.recordFile(in: directory))
}

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct PasswordChangeTests {
	private let alarm = Alarm()

	private func library(calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { UnlockParameters.fast.argon }, holdingWritesAt gate: Gate? = nil) -> Workspace {
		Workspace(holding: ["Shopping", "Trip"]) { [alarm] directory, keys in
			let records = gate.map { GatedRecords(records: FileUnlockRecordStore(directory: directory), gate: $0) }
			return AppModel.testing(in: directory, scheduler: alarm.scheduler, calibrate: calibrate, keyStore: keys, records: records)
		}
	}

	private func relaunch(_ directory: URL, password: String) async -> AppModel {
		let model = AppModel.testing(in: directory)
		model.start()
		await model.submit(password: password)
		return model
	}

	@Test func theNewPasswordUnlocksAndTheOldOneNoLonger() async throws {
		let (model, directory) = try await library().unlocked()
		let bodies = Set(model.notes.map(\.body))

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		await model.lock()

		let relaunched = await relaunch(directory, password: "a new password")
		#expect(relaunched.phase == .unlocked)
		#expect(Set(relaunched.notes.map(\.body)) == bodies)
		await relaunched.lock()
		await relaunched.submit(password: workspacePassword)
		#expect(relaunched.failure == .wrongPassword)
	}

	@Test func aWrongCurrentPasswordChangesNothing() async throws {
		let (model, directory) = try await library().unlocked()
		let record = try recordBytes(in: directory)

		#expect(await model.changePassword(from: "a guess", to: "a new password") == .wrongPassword)

		#expect(model.failure == nil)
		#expect(try recordBytes(in: directory) == record)
		await model.createNote()
		#expect(model.failure == nil)
	}

	@Test func aLockedLibraryKeepsItsPassword() async throws {
		let (model, directory) = try await library().unlocked()
		let record = try recordBytes(in: directory)
		await model.lock()

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") != nil)

		#expect(try recordBytes(in: directory) == record)
	}

	@Test func aSecondChangeStartsFromTheFirst() async throws {
		let (model, directory) = try await library().unlocked()

		#expect(await model.changePassword(from: workspacePassword, to: "second password") == nil)
		#expect(await model.changePassword(from: "second password", to: "third password") == nil)
		await model.lock()

		#expect(await relaunch(directory, password: "third password").phase == .unlocked)
	}

	@Test func anEditWaitingToSaveLandsUnderTheNewPassword() async throws {
		let (model, directory) = try await library().unlocked()
		model.edit(try #require(model.selection), "typed before the change")

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(await model.flushPendingSaves())
		await model.lock()

		#expect(await relaunch(directory, password: "a new password").notes.contains { $0.body == "typed before the change" })
	}

	@Test func changingThePasswordKeepsTouchIDOn() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlocked(keys)
		try await turnOnTouchID(model)
		let key = keys.storedKey

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == key)

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .wrongPassword)
		await model.lock()
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
		#expect(model.failure == nil)
	}

	@Test func lockingDuringTheChangeKeepsTheOldPassword() async throws {
		let gate = Gate()
		defer { gate.open() }
		let (model, directory) = try await library(calibrate: gate.holdCalibration).unlocked()
		let record = try recordBytes(in: directory)

		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()
		try #require(gate.isHolding)
		let locking = Task { await model.lock() }
		try await settle { model.phase == .locked }
		gate.open()
		await locking.value

		#expect(await change.value != nil)
		#expect(try recordBytes(in: directory) == record)
		#expect(await relaunch(directory, password: workspacePassword).phase == .unlocked)
	}

	@Test func aSecondChangeWhileOneRunsIsRefused() async throws {
		let gate = Gate()
		defer { gate.open() }
		let (model, directory) = try await library(calibrate: { gate.isHolding ? UnlockParameters.fast.argon : gate.holdCalibration() }).unlocked()

		let first = Task { await model.changePassword(from: workspacePassword, to: "second password") }
		try await gate.untilHolding()
		#expect(await model.changePassword(from: workspacePassword, to: "third password") != nil)
		gate.open()

		#expect(await first.value == nil)
		await model.lock()
		#expect(await relaunch(directory, password: "second password").phase == .unlocked)
	}

	@Test func lockingAndUnlockingWaitForAChangeWritingItsRecord() async throws {
		let gate = Gate()
		defer { gate.open() }
		let (model, directory) = try await library(holdingWritesAt: gate).unlocked()
		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()

		let locked = Flag()
		let locking = Task {
			await model.lock()
			locked.raise()
		}
		try await settle { model.phase == .locked }
		let answered = Flag()
		let unlocking = Task {
			await model.unlock(password: workspacePassword)
			answered.raise()
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(!locked.isRaised)
		#expect(!answered.isRaised)
		gate.open()

		#expect(await change.value == nil)
		await locking.value
		await unlocking.value
		#expect(model.failure == .wrongPassword)
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}

	@Test func quittingWaitsForAChangeWritingItsRecord() async throws {
		let gate = Gate()
		defer { gate.open() }
		let (model, directory) = try await library(holdingWritesAt: gate).unlocked()
		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()

		let closed = Flag()
		let closing = Task {
			await model.close()
			closed.raise()
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(!closed.isRaised)
		gate.open()

		#expect(await change.value == nil)
		await closing.value
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}

	@Test func aPasswordChangeDuringTheTouchIDCheckLeavesAKeyThatStillOpensTheLibrary() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library().unlocked(keys)
		keys.whileLoading {
			#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		}

		#expect(await enableTouchID(model) == nil)

		#expect(model.isBiometricUnlockEnabled)
		await model.lock()
		keys.whileLoading {}
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
		await model.lock()
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}

	@Test func aPasswordChangeStillRunningWhenTouchIDAnswersLeavesNoKey() async throws {
		let gate = Gate()
		defer { gate.open() }
		let keys = FakeKeyStore()
		let (model, directory) = try await library(calibrate: gate.holdCalibration).unlocked(keys)
		let promptIsUp = AsyncStream<Void>.makeStream()
		let change = Task {
			for await _ in promptIsUp.stream { break }
			return await model.changePassword(from: workspacePassword, to: "a new password")
		}
		keys.whileLoading {
			promptIsUp.continuation.yield()
			try? await gate.untilHolding()
		}

		#expect(await enableTouchID(model) == nil)

		#expect(gate.isHolding)
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		gate.open()
		#expect(await change.value == nil)
		#expect(keys.storedKey == nil)
		await model.lock()
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}
}
