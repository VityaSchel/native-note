import Foundation
import Synchronization
import Testing

@testable import NativeNoteKit

private final class CalibrationGate: Sendable {
	private let entered = Mutex(false)
	private let release = DispatchSemaphore(value: 0)

	var isHolding: Bool { entered.withLock { $0 } }

	func hold() -> Argon2.Parameters {
		entered.withLock { $0 = true }
		release.wait()
		return UnlockParameters.fast.argon
	}

	func open() {
		release.signal()
	}
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct PasswordChangeTests {
	private let alarm = Alarm()

	private func library(
		_ keys: FakeKeyStore = FakeKeyStore(),
		calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { UnlockParameters.fast.argon }
	) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), calibrate: calibrate, keyStore: keys)
		}
		try await fill(model, with: ["Shopping", "Trip"])
		return (model, directory)
	}

	private func relaunch(_ directory: URL, password: String) async -> AppModel {
		let model = AppModel(directory: directory, keyStore: FakeKeyStore())
		model.start()
		await model.submit(password: password)
		return model
	}

	@Test func theNewPasswordUnlocksAndTheOldOneNoLonger() async throws {
		let (model, directory) = try await library()
		defer { try? FileManager.default.removeItem(at: directory) }
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
		let (model, directory) = try await library()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try Data(contentsOf: AppLock.currentFile(in: directory))

		#expect(await model.changePassword(from: "a guess", to: "a new password") == .wrongPassword)

		#expect(model.failure == nil)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try Data(contentsOf: AppLock.currentFile(in: directory)) == parameters)
		await model.createNote()
		#expect(model.failure == nil)
	}

	@Test func aLockedLibraryKeepsItsPassword() async throws {
		let (model, directory) = try await library()
		defer { try? FileManager.default.removeItem(at: directory) }
		let parameters = try Data(contentsOf: AppLock.currentFile(in: directory))
		await model.lock()

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") != nil)

		#expect(try Data(contentsOf: AppLock.currentFile(in: directory)) == parameters)
	}

	@Test func aSecondChangeStartsFromTheFirst() async throws {
		let (model, directory) = try await library()
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await model.changePassword(from: workspacePassword, to: "second password") == nil)
		#expect(await model.changePassword(from: "second password", to: "third password") == nil)
		await model.lock()

		#expect(await relaunch(directory, password: "third password").phase == .unlocked)
	}

	@Test func anEditWaitingToSaveLandsUnderTheNewPassword() async throws {
		let (model, directory) = try await library()
		defer { try? FileManager.default.removeItem(at: directory) }
		model.edit(try #require(model.selection), "typed before the change")

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(await model.flushPendingSaves())
		await model.lock()

		#expect(await relaunch(directory, password: "a new password").notes.contains { $0.body == "typed before the change" })
	}

	@Test func changingThePasswordTurnsTouchIDOffUntilItIsTurnedOnAgain() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		#expect(model.isBiometricUnlockEnabled)

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.storedKey == nil)

		#expect(await model.enableBiometricUnlock())
		await model.lock()
		await model.unlockWithBiometrics()
		#expect(model.phase == .unlocked)
		#expect(model.failure == nil)
	}

	@Test func lockingDuringTheChangeKeepsTheOldPassword() async throws {
		let gate = CalibrationGate()
		let (model, directory) = try await library(calibrate: gate.hold)
		defer { try? FileManager.default.removeItem(at: directory) }

		let change = Task { await model.changePassword(from: workspacePassword, to: "a new password") }
		for _ in 0 ..< 2_000 where !gate.isHolding {
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(gate.isHolding)
		await model.lock()
		gate.open()

		#expect(await change.value != nil)
		#expect(await relaunch(directory, password: workspacePassword).phase == .unlocked)
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
	}
}
