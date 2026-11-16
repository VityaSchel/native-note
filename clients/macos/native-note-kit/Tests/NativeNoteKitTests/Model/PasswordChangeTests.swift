import Foundation
import Testing

@testable import NativeNoteKit

private extension Gate {
	func holdCalibration() -> Argon2.Parameters {
		hold()
		return UnlockParameters.fast.argon
	}
}

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct PasswordChangeTests {
	private let alarm = Alarm()

	private func library(calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { UnlockParameters.fast.argon }) -> Workspace {
		Workspace(holding: ["Shopping", "Trip"]) { [alarm] directory, keys in
			AppModel.testing(in: directory, scheduler: alarm.scheduler, calibrate: calibrate, keyStore: keys)
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
		let parameters = try Data(contentsOf: AppLock.currentFile(in: directory))

		#expect(await model.changePassword(from: "a guess", to: "a new password") == .wrongPassword)

		#expect(model.failure == nil)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try Data(contentsOf: AppLock.currentFile(in: directory)) == parameters)
		await model.createNote()
		#expect(model.failure == nil)
	}

	@Test func aLockedLibraryKeepsItsPassword() async throws {
		let (model, directory) = try await library().unlocked()
		let parameters = try Data(contentsOf: AppLock.currentFile(in: directory))
		await model.lock()

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") != nil)

		#expect(try Data(contentsOf: AppLock.currentFile(in: directory)) == parameters)
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

	@Test func changingThePasswordTurnsTouchIDOffUntilItIsTurnedOnAgain() async throws {
		let keys = FakeKeyStore()
		let (model, _) = try await library().unlocked(keys)
		try await turnOnTouchID(model)

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .wrongPassword)
		try await turnOnTouchID(model, password: "a new password")
		await model.lock()
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
		#expect(model.failure == nil)
	}

	@Test func lockingDuringTheChangeKeepsTheOldPassword() async throws {
		let gate = Gate()
		defer { gate.open() }
		let (model, directory) = try await library(calibrate: gate.holdCalibration).unlocked()

		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()
		try #require(gate.isHolding)
		let locking = Task { await model.lock() }
		try await settle { model.phase == .locked }
		gate.open()
		await locking.value

		#expect(await change.value != nil)
		#expect(await relaunch(directory, password: workspacePassword).phase == .unlocked)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
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
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		await model.lock()
		#expect(await relaunch(directory, password: "second password").phase == .unlocked)
	}

	@Test func lockingAndUnlockingWaitForAChangePastItsRekey() async throws {
		let gate = Gate()
		defer { gate.open() }
		let keys = FakeKeyStore()
		let (model, directory) = try await library().unlocked(keys)
		keys.whileDeleting { gate.hold() }
		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()
		try #require(AppLock.parameterFiles(in: directory).count == 2)

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
		#expect(AppLock.parameterFiles(in: directory).count == 2)
		keys.whileDeleting {}
		gate.open()

		#expect(await change.value == nil)
		await locking.value
		await unlocking.value
		#expect(model.failure == .wrongPassword)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}

	@Test func quittingWaitsForAChangePastItsRekey() async throws {
		let gate = Gate()
		defer { gate.open() }
		let keys = FakeKeyStore()
		let (model, directory) = try await library().unlocked(keys)
		keys.whileDeleting { gate.hold() }
		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		try await gate.untilHolding()

		let closed = Flag()
		let closing = Task {
			await model.close()
			closed.raise()
		}
		try await Task.sleep(for: .milliseconds(200))
		#expect(!closed.isRaised)
		keys.whileDeleting {}
		gate.open()

		#expect(await change.value == nil)
		await closing.value
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(await relaunch(directory, password: "a new password").phase == .unlocked)
	}

	@Test func aPendingFileLostDuringTheRekeyStillLeavesTheNewPasswordInCharge() async throws {
		let directory = temporaryDirectory()
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		let store = try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey())
		try await store.save(sampleNote(body: "kept"))
		let keys = FakeKeyStore()
		keys.whileDeleting { try? FileManager.default.removeItem(at: AppLock.pendingRekeyFile(in: directory)) }

		let changed = try await Unlock.changePassword(
			from: workspacePassword,
			to: "a new password",
			parameters: .fast,
			store: store,
			in: directory,
			storedKey: keys,
			calibrate: { UnlockParameters.fast.argon }
		)
		await store.close()

		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == changed.parameters)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		let reopened = try await Unlock.open(password: "a new password", in: directory)
		#expect(try await reopened.store.liveNotes().map(\.body) == ["kept"])
	}

	@Test func aPasswordChangeDuringTheTouchIDCheckLeavesNoStaleKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library().unlocked(keys)
		let staleKey = try await workspaceKey()
		keys.whileLoading {
			#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
			keys.plant(staleKey)
		}

		#expect(await enableTouchID(model) == nil)

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
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
