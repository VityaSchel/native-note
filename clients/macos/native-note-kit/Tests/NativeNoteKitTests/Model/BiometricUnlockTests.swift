import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BiometricUnlockTests {
	private let alarm = Alarm()

	private func library(_ keys: FakeKeyStore, _ bodies: [String] = ["Shopping", "Trip"]) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), keyStore: keys)
		}
		try await fill(model, with: bodies)
		return (model, directory)
	}

	@Test func touchIDUnlocksOnceItIsTurnedOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let bodies = Set(model.notes.map(\.body))

		#expect(await model.enableBiometricUnlock())
		#expect(model.isBiometricUnlockEnabled)
		#expect(!model.canUnlockWithBiometrics)
		await model.lock()
		#expect(model.canUnlockWithBiometrics)

		await model.unlockWithBiometrics()

		#expect(model.phase == .unlocked)
		#expect(Set(model.notes.map(\.body)) == bodies)
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func theButtonStaysHiddenUntilTouchIDIsTurnedOn() async throws {
		let (model, directory) = try await library(FakeKeyStore())
		defer { try? FileManager.default.removeItem(at: directory) }

		await model.lock()

		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func cancellingTouchIDLeavesTheLockScreenAsItWas() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		keys.reply(with: .cancel)

		await model.unlockWithBiometrics()

		#expect(model.phase == .locked)
		#expect(model.failure == nil)
		#expect(keys.storedKey != nil)
		#expect(model.canUnlockWithBiometrics)
	}

	@Test func aKeyTouchIDCannotReadIsForgottenWithAnExplanation() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		keys.reply(with: .failure)

		await model.unlockWithBiometrics()

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("Touch ID could not read the unlock key. Unlock with your password."))
		#expect(keys.storedKey == nil)
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func aStoredKeyThatNoLongerOpensTheNotesIsForgotten() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()
		keys.plant(Data(repeating: 0x42, count: 32))

		await model.unlockWithBiometrics()

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("The key saved for Touch ID no longer opens these notes. Unlock with your password."))
		#expect(keys.storedKey == nil)
		await model.submit(password: workspacePassword)
		#expect(model.phase == .unlocked)
	}

	@Test func turningTouchIDOffForgetsTheKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())

		model.disableBiometricUnlock()

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		await model.lock()
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func aMacWithoutTouchIDSavesNothing() async throws {
		let keys = FakeKeyStore(available: false)
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await !model.enableBiometricUnlock())
		#expect(keys.storedKey == nil)
		keys.plant(Data(repeating: 0x42, count: 32))
		await model.lock()
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func lockingForgetsTheKeyItCouldHaveSaved() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		await model.lock()

		#expect(await !model.enableBiometricUnlock())
		#expect(keys.storedKey == nil)
	}

	@Test func theSavedKeyIsTheOneThatOpensTheNotes() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await model.enableBiometricUnlock())

		#expect(keys.storedKey == (try await workspaceKey()))
	}

	@Test func theButtonShowsAtLaunchWhenAKeyIsStored() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()

		#expect(relaunched.canUnlockWithBiometrics)
	}

	@Test func aNewLibraryForgetsTheKeyOfTheOneBeforeIt() async throws {
		let keys = FakeKeyStore()
		keys.plant(Data(repeating: 0x42, count: 32))
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		model.start()
		#expect(model.isBiometricUnlockEnabled)

		await model.submit(password: "fresh start")
		#expect(model.phase == .unlocked)
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		await model.lock()

		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func aSetUpThatFindsAnotherLibraryKeepsItsKey() async throws {
		let keys = FakeKeyStore()
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		model.start()
		let other = try await Unlock.setUp(password: "other instance", in: directory, makeParameters: { .fast })
		await other.store.close()
		try keys.save(other.key)

		await model.submit(password: "correct horse")

		#expect(model.phase == .locked)
		#expect(keys.storedKey == other.key)
	}

	@Test func touchIDArrivingAfterAPasswordUnlockChangesNothing() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		let id = try #require(model.notes.first?.id)
		model.edit(id, "typed after the password unlock")

		await model.unlockWithBiometrics()

		#expect(model.notes.first { $0.id == id }?.body == "typed after the password unlock")
	}

	@Test func aLibraryThatFailsToLoadKeepsNeitherTheDatabaseNorTheKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()
		try await connection(to: directory).execute("ALTER TABLE note RENAME TO kept; CREATE TABLE note (uuid BLOB PRIMARY KEY)")

		await model.submit(password: workspacePassword)
		try #require(model.phase == .locked)

		#expect(!FileManager.default.fileExists(atPath: walFile(of: AppLock.databaseFile(in: directory)).path))
		#expect(await !model.enableBiometricUnlock())
		#expect(keys.storedKey == nil)
	}

	@Test func touchIDThatCannotFindTheDatabaseKeepsTheKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		try FileManager.default.removeItem(at: AppLock.databaseFile(in: directory))

		await model.unlockWithBiometrics()

		#expect(model.failure == .unexpected("The notes database is missing."))
		#expect(keys.storedKey != nil)
	}

	@Test func aKeychainThatRefusesWritesSaysSo() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.failWrites()
		let refusal = KeychainFailure(status: errSecNotAvailable).message

		#expect(await !model.enableBiometricUnlock())
		#expect(model.failure == .unexpected("Touch ID unlock could not be turned on. \(refusal)"))

		model.disableBiometricUnlock()
		#expect(model.failure == .unexpected("Touch ID unlock could not be turned off. \(refusal)"))
	}

	@Test func turningTouchIDOffOnTheLockScreenHidesTheButton() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		try #require(model.canUnlockWithBiometrics)

		model.disableBiometricUnlock()

		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func turningTouchIDOnAsksForTouchIDFirst() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		#expect(await model.enableBiometricUnlock())

		#expect(keys.reasons == ["turn on Touch ID unlock"])
		#expect(model.isBiometricUnlockEnabled)
	}

	@Test func cancellingTheTouchIDCheckLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)

		#expect(await !model.enableBiometricUnlock())

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure == nil)
	}

	@Test func aTouchIDCheckThatFailsSaysSoAndLeavesItOff() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)

		#expect(await !model.enableBiometricUnlock())

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		#expect(model.failure != nil)
	}

	@Test func aKeyThatReadsBackDifferentlyIsNotKept() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .otherKey)

		#expect(await !model.enableBiometricUnlock())

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
	}

	@Test func lockingDuringTheTouchIDCheckKeepsNoKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading { await model.lock() }

		#expect(await !model.enableBiometricUnlock())

		#expect(model.phase == .locked)
		#expect(keys.storedKey == nil)
		#expect(!model.canUnlockWithBiometrics)
	}

	@Test func aLibraryThatStartsLockedOffersTouchIDRightAway() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()

		#expect(relaunched.offersBiometricUnlock)
	}

	@Test func lockingByHandOffersTouchIDOnlyOnceTheAppIsReturnedTo() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())

		await model.lock()
		#expect(!model.offersBiometricUnlock)
		model.offerBiometricUnlock()

		#expect(model.offersBiometricUnlock)
	}

	@Test func typingThePasswordInsteadDropsTheOffer() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()
		#expect(relaunched.offersBiometricUnlock)

		await relaunched.submit(password: workspacePassword)
		#expect(relaunched.phase == .unlocked)
		await relaunched.lock()

		#expect(!relaunched.offersBiometricUnlock)
	}

	@Test func nothingIsOfferedWithoutTouchIDOrWhileUnlocked() async throws {
		let (model, directory) = try await library(FakeKeyStore())
		defer { try? FileManager.default.removeItem(at: directory) }

		model.offerBiometricUnlock()
		#expect(!model.offersBiometricUnlock)
		await model.lock()
		model.offerBiometricUnlock()
		#expect(!model.offersBiometricUnlock)
	}

	@Test func thePromptTakesTheOfferAndRefusesNewOnesWhileItIsUp() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(await model.enableBiometricUnlock())
		await model.lock()
		model.offerBiometricUnlock()
		let seen = PromptState()
		keys.reply(with: .cancel)
		keys.whileLoading {
			let state = await MainActor.run {
				model.offerBiometricUnlock()
				return (model.isPromptingBiometrics, model.offersBiometricUnlock)
			}
			await seen.record(prompting: state.0, offered: state.1)
		}

		await model.unlockWithBiometrics()

		#expect(await seen.prompting)
		#expect(await !seen.offered)
		#expect(!model.isPromptingBiometrics)
		#expect(!model.offersBiometricUnlock)
		#expect(model.phase == .locked)
	}
}

private actor PromptState {
	private(set) var prompting = false
	private(set) var offered = true

	func record(prompting: Bool, offered: Bool) {
		self.prompting = prompting
		self.offered = offered
	}
}
