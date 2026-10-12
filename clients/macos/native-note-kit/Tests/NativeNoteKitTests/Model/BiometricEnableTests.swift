import CryptoKit
import Foundation
import LocalAuthentication
import Testing

@testable import NativeNoteKit

private func keyMaterial(in subject: Any, at path: String, seen: inout Set<ObjectIdentifier>) -> [String] {
	if subject is SymmetricKey { return [path] }
	if let bytes = subject as? Data, bytes.count == 32 { return [path] }
	if let bytes = subject as? [UInt8], bytes.count == 32 { return [path] }
	let mirror = Mirror(reflecting: subject)
	if mirror.displayStyle == .class, !seen.insert(ObjectIdentifier(subject as AnyObject)).inserted { return [] }
	return mirror.children.enumerated().flatMap { index, child in
		keyMaterial(in: child.value, at: path + "." + (child.label ?? String(index)), seen: &seen)
	}
}

private let modelDependencies: Set = ["keyStore", "makeParameters", "calibrate", "searchNotes", "shakeTimer", "makeTransport"]

private func isOpaque(_ value: Any) -> Bool {
	let mirror = Mirror(reflecting: value)
	if mirror.displayStyle == .optional { return mirror.children.first.map { isOpaque($0.value) } ?? false }
	let type = String(describing: Swift.type(of: value))
	return type.contains("->") || type.hasPrefix("Task<")
}

@MainActor
private func keyMaterial(in model: AppModel) -> [String] {
	var seen: Set<ObjectIdentifier> = [ObjectIdentifier(model)]
	return Mirror(reflecting: model).children
		.filter { !modelDependencies.contains($0.label ?? "") }
		.flatMap { child in
			let label = child.label ?? ""
			return isOpaque(child.value) ? [label] : keyMaterial(in: child.value, at: label, seen: &seen)
		}
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BiometricEnableTests {
	private let alarm = Alarm()

	private func library(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(
				directory: directory,
				scheduler: SaveScheduler(sleep: alarm.sleep),
				calibrate: { UnlockParameters.fast.argon },
				keyStore: keys
			)
		}
		try await fill(model, with: ["Shopping", "Trip"])
		return (model, directory)
	}

	private func listeningToTurnOn(_ model: AppModel, password: String = workspacePassword) async throws -> Task<AppModel.Failure?, Never> {
		model.appBecameActive()
		let enabling = Task { await model.enableBiometricUnlock(password: password) }
		for _ in 0 ..< 2_000 where model.touchID.listeningContext == nil {
			try await Task.sleep(for: .milliseconds(5))
		}
		try #require(model.touchID.listeningContext != nil)
		return enabling
	}

	@Test func turningTouchIDOnTakesThePasswordThenListensForATouch() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		let enabling = try await listeningToTurnOn(model)
		#expect(keys.storedKey == (try await workspaceKey()))
		#expect(!model.isBiometricUnlockEnabled)
		#expect(keys.reasons.isEmpty)
		#expect(await touch(model))

		#expect(await enabling.value == nil)
		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
		#expect(model.failure == nil)
	}

	@Test func theSwitchStaysOffWhileTouchIDIsAwaited() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)

		model.appResignedActive()
		model.appBecameActive()

		#expect(!model.isBiometricUnlockEnabled)
		model.cancelTurningOnTouchID()
		#expect(await enabling.value == nil)
	}

	@Test func aWrongFingerWhileTurningOnWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		keys.reply(with: .miss)

		#expect(await touch(model))
		#expect(model.touchID == .needsClick(after: .miss))
		#expect(model.shake.count == 0)
		#expect(await !touch(model))
		model.appResignedActive()
		model.appBecameActive()
		#expect(model.touchID == .needsClick(after: .miss))
		model.tryTouchIDAgain()
		keys.reply(with: .key)
		#expect(await touch(model))

		#expect(await enabling.value == nil)
		#expect(model.isBiometricUnlockEnabled)
		#expect(keys.contexts.count == 2)
		#expect(keys.contexts[0] !== keys.contexts[1])
	}

	@Test func leavingTheAppWhileTurningOnListensAgainOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		let first = try #require(model.touchID.listeningContext)

		model.appResignedActive()
		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		model.appBecameActive()
		#expect(model.touchID.listeningContext !== first)
		#expect(await touch(model))

		#expect(await enabling.value == nil)
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func anInterruptedTouchWhileTurningOnWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		keys.reply(with: .cancel)

		#expect(await touch(model))

		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(!model.isBiometricUnlockEnabled)
		model.tryTouchIDAgain()
		keys.reply(with: .key)
		#expect(await touch(model))
		#expect(await enabling.value == nil)
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func cancellingWhileTouchIDIsAwaitedLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		let listening = try #require(model.touchID.listeningContext)

		model.cancelTurningOnTouchID()

		#expect(await enabling.value == nil)
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
		#expect(isInvalidated(listening))
		#expect(keys.contexts.isEmpty)
		#expect(model.failure == nil)
	}

	@Test func cancellingStopsListeningAtOnce() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		let listening = try #require(model.touchID.listeningContext)

		model.cancelTurningOnTouchID()

		#expect(isInvalidated(listening))
		#expect(model.touchID == .hidden)
		#expect(await enabling.value == nil)
	}

	@Test func aLockoutWhileTurningOnSaysSoAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .lockout)

		#expect(await enableTouchID(model) == .unexpected("Touch ID unlock could not be turned on. Touch ID is locked."))

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
	}

	@Test func touchIDGoingAwayWhileTurningOnSaysSoAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .unavailable)

		#expect(await enableTouchID(model) == .unexpected("Touch ID unlock could not be turned on. Touch ID is not available."))

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func quittingWhileTouchIDIsAwaitedKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)

		await model.close()

		#expect(await enabling.value == nil)
		#expect(keys.storedKey == nil)
	}

	@Test func theSavedKeyIsTheOneThatOpensTheNotes() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		try await turnOnTouchID(model)

		#expect(keys.storedKey == (try await workspaceKey()))
	}

	@Test func aWrongPasswordTurnsNothingOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		model.appBecameActive()

		#expect(await model.enableBiometricUnlock(password: "a guess") == .wrongPassword)

		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
		#expect(model.touchID == .hidden)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
		await model.createNote()
		#expect(model.failure == nil)
	}

	@Test func aWrongPasswordLeavesTheSavedKeyAlone() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await turnOnTouchID(model)

		#expect(await model.enableBiometricUnlock(password: "a guess") == .wrongPassword)

		#expect(keys.storedKey == (try await workspaceKey()))
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func turningTouchIDOnNeedsAnUnlockedLibrary() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .unexpected("Unlock Native Note to turn on Touch ID unlock."))

		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
	}

	@Test func aMacWithoutTouchIDSavesNothing() async throws {
		let keys = FakeKeyStore(available: false)
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .unexpected("Touch ID is not available on this Mac."))
		#expect(keys.storedKey == nil)
		keys.plant(SymmetricKey(data: Data(repeating: 0x42, count: 32)))
		model.appBecameActive()
		await model.lock()
		#expect(model.touchID == .hidden)
	}

	@Test func aTouchIDCheckThatFailsSaysSoAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)
		let reason = KeychainFailure(status: errSecItemNotFound).message

		#expect(await enableTouchID(model) == .unexpected("Touch ID unlock could not be turned on. \(reason)"))

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func aKeyThatReadsBackDifferentlyIsNotKept() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .otherKey)

		#expect(await enableTouchID(model) == .unexpected("Touch ID unlock could not be turned on. Try again."))

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func aKeychainThatRefusesWritesSaysSo() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.failWrites()
		let refusal = KeychainFailure(status: errSecNotAvailable).message

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .unexpected("Touch ID unlock could not be turned on. \(refusal)"))
		#expect(model.failure == nil)
		#expect(keys.reasons.isEmpty)

		model.disableBiometricUnlock()
		#expect(model.failure == .unexpected("Touch ID unlock could not be turned off. \(refusal)"))
	}

	@Test func lockingWhileThePasswordIsCheckedKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)

		let enabling = Task { await model.enableBiometricUnlock(password: workspacePassword) }
		await Task.yield()
		await model.lock()
		gate.open()

		#expect(await enabling.value == nil)
		try await holding.value
		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
		#expect(model.touchID == .hidden)
	}

	@Test func lockingWhileTouchIDIsAwaitedKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let enabling = try await listeningToTurnOn(model)
		let listening = try #require(model.touchID.listeningContext)

		await model.lock()

		#expect(await enabling.value == nil)
		#expect(model.phase == .locked)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
		#expect(isInvalidated(listening))
	}

	@Test func lockingDuringTheTouchIDCheckKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading { await model.lock() }

		#expect(await enableTouchID(model) == nil)

		#expect(model.phase == .locked)
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func unlockingAgainDuringTheTouchIDCheckKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading {
			await model.lock()
			await model.submit(password: workspacePassword)
		}

		#expect(await enableTouchID(model) == nil)

		#expect(model.phase == .unlocked)
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func anUnlockedLibraryKeepsNoCopyOfItsKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		var probe: Set<ObjectIdentifier> = []
		try #require(!keyMaterial(in: [databaseKey], at: "probe", seen: &probe).isEmpty)
		try #require(!keyMaterial(in: ["probe": databaseKey.withUnsafeBytes { Data($0) }], at: "probe", seen: &probe).isEmpty)
		try #require(Mirror(reflecting: model).children.contains { $0.label == "_unlockParameters" })
		try #require(Set(Mirror(reflecting: model).children.filter { isOpaque($0.value) }.compactMap(\.label)).isSuperset(of: modelDependencies.subtracting(["keyStore"])))
		try #require(isOpaque(Optional(Task { databaseKey }) as Any))
		#expect(keyMaterial(in: model).isEmpty)

		try await turnOnTouchID(model)
		#expect(keyMaterial(in: model).isEmpty)

		#expect(await model.changePassword(from: workspacePassword, to: "a new password") == nil)
		#expect(keyMaterial(in: model).isEmpty)

		try await turnOnTouchID(model, password: "a new password")
		await model.lock()
		#expect(keyMaterial(in: model).isEmpty)
		await touch(model)
		try #require(model.phase == .unlocked)
		#expect(keyMaterial(in: model).isEmpty)
	}
}
