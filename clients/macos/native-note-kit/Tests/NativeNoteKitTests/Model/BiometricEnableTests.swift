import CryptoKit
import Foundation
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

private let modelDependencies: Set = ["keyStore", "makeParameters", "calibrate", "searchNotes"]

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

	@Test func turningTouchIDOnTakesThePasswordThenAsksForTouchID() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == nil)

		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
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

		#expect(await model.enableBiometricUnlock(password: "a guess") == .wrongPassword)

		#expect(keys.storedKey == nil)
		#expect(keys.reasons.isEmpty)
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
		await model.lock()
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func cancellingTheTouchIDCheckLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == nil)

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func aTouchIDCheckThatFailsSaysSoAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)
		let reason = KeychainFailure(status: errSecItemNotFound).message

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .unexpected("Touch ID unlock could not be turned on. \(reason)"))

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func aKeyThatReadsBackDifferentlyIsNotKept() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .otherKey)

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == .unexpected("Touch ID unlock could not be turned on. Try again."))

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
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func lockingDuringTheTouchIDCheckKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading { await model.lock() }

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == nil)

		#expect(model.phase == .locked)
		#expect(keys.storedKey == nil)
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func unlockingAgainDuringTheTouchIDCheckKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading {
			await model.lock()
			await model.submit(password: workspacePassword)
		}

		#expect(await model.enableBiometricUnlock(password: workspacePassword) == nil)

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
		await model.unlockWithBiometrics()
		try #require(model.phase == .unlocked)
		#expect(keyMaterial(in: model).isEmpty)
	}
}
