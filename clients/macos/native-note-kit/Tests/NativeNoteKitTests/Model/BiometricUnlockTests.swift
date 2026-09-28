import CryptoKit
import Foundation
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import Testing

@testable import NativeNoteKit

@MainActor
private final class Hook {
	var body: (() async -> Void)?

	func run() async {
		let body = body
		self.body = nil
		await body?()
	}
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct BiometricUnlockTests {
	private let alarm = Alarm()
	private let shaking = Alarm()
	private let duringSearch = Hook()

	private func library(_ keys: FakeKeyStore, _ bodies: [String] = ["Shopping", "Trip"]) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm, shaking, duringSearch] directory in
			AppModel(
				directory: directory,
				scheduler: SaveScheduler(sleep: alarm.sleep),
				searchNotes: { store, text in
					await duringSearch.run()
					return try await store.search(text)
				},
				keyStore: keys,
				shakeTimer: shaking.sleep
			)
		}
		try await fill(model, with: bodies)
		return (model, directory)
	}

	private func lockedWithTouchID(_ keys: FakeKeyStore) async throws -> (AppModel, URL) {
		let (model, directory) = try await library(keys)
		try await turnOnTouchID(model)
		await model.lock()
		keys.forgetReads()
		return (model, directory)
	}

	@Test func touchIDUnlocksOnceItIsTurnedOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let bodies = Set(model.notes.map(\.body))

		try await turnOnTouchID(model)
		#expect(model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)
		await model.lock()
		#expect(model.touchID.listeningContext != nil)

		#expect(await touch(model))

		#expect(model.phase == .unlocked)
		#expect(Set(model.notes.map(\.body)) == bodies)
		#expect(model.touchID == .hidden)
		#expect(model.failure == nil)
	}

	@Test func nothingListensUntilTouchIDIsTurnedOn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		model.appBecameActive()

		await model.lock()

		#expect(model.touchID == .hidden)
		#expect(await !touch(model))
		#expect(keys.contexts.isEmpty)
	}

	@Test func nothingListensOnAMacWithoutTouchID() async throws {
		let keys = FakeKeyStore()
		let (_, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.becomes(.unavailable)

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()
		relaunched.appBecameActive()

		#expect(relaunched.touchID == .hidden)
	}

	@Test func aLibraryThatStartsLockedListensOnceTheAppIsInFront() async throws {
		let keys = FakeKeyStore()
		let (_, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()
		#expect(relaunched.touchID == .paused(.inBackground))
		relaunched.appBecameActive()

		#expect(relaunched.touchID.listeningContext != nil)
		#expect(await touch(relaunched))
		#expect(relaunched.phase == .unlocked)
	}

	@Test func nothingListensBeforeTheLibraryIsLoaded() async throws {
		let keys = FakeKeyStore()
		keys.plant(SymmetricKey(data: Data(repeating: 0x42, count: 32)))
		let model = AppModel(directory: temporaryDirectory(), keyStore: keys)

		model.appBecameActive()

		#expect(model.phase == .loading)
		#expect(model.touchID == .hidden)
	}

	@Test func lockingByHandListensRightAway() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await turnOnTouchID(model)

		await model.lock()

		#expect(model.touchID.listeningContext != nil)
	}

	@Test func anotherAppInFrontStopsListeningAndReturningStartsAFreshAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try #require(model.touchID.listeningContext)

		model.appResignedActive()

		#expect(model.touchID == .paused(.inBackground))
		#expect(isInvalidated(first))
		#expect(await !touch(model))
		model.appBecameActive()
		let second = try #require(model.touchID.listeningContext)
		#expect(second !== first)
		#expect(!isInvalidated(second))
	}

	@Test func becomingActiveAgainKeepsTheAttemptThatIsListening() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		model.appBecameActive()

		#expect(model.touchID.listeningContext === listening)
		#expect(!isInvalidated(listening))
	}

	@Test func anAttemptStoppedByLeavingTheAppChangesNothingWhenItAnswers() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading { @MainActor in
			model.appResignedActive()
			model.appBecameActive()
		}

		#expect(await touch(model))

		#expect(model.phase == .locked)
		#expect(model.touchID.listeningContext != nil)
		#expect(model.touchID.listeningContext !== keys.contexts.first)
		keys.whileLoading {}
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
	}

	private func endShake(of model: AppModel) async {
		await ring(shaking)
		await settle { !model.shake.isRunning }
	}

	@Test func aWrongFingerShakesTheFieldAndAFreshAttemptListensOnceTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)

		#expect(await touch(model))

		#expect(model.shake == AppModel.Shake(count: 1, isRunning: true))
		#expect(model.touchID == .paused(.shaking))
		#expect(model.failure == nil)
		#expect(keys.storedKey != nil)
		#expect(await !touch(model))
		#expect(keys.contexts.count == 1)

		await endShake(of: model)

		#expect(await shaking.requested == [.milliseconds(400)])
		let again = try #require(model.touchID.listeningContext)
		#expect(again !== keys.contexts.first)
		#expect(!isInvalidated(again))
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: false))
		keys.reply(with: .key)
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
		#expect(keys.contexts.count == 2)
	}

	@Test func nothingListensWhileTheFieldShakes() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		await touch(model)
		var seen: [AppModel.TouchID] = []

		for _ in 0 ..< 200 {
			await Task.yield()
			seen.append(model.touchID)
		}
		model.appResignedActive()
		seen.append(model.touchID)
		model.appBecameActive()
		seen.append(model.touchID)

		#expect(seen.allSatisfy { $0 == .paused(.shaking) })
		#expect(await !touch(model))
		#expect(keys.contexts.count == 1)
		await endShake(of: model)
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func aShakeThatEndsWhileAnotherAppIsInFrontListensOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		await touch(model)
		model.appResignedActive()

		await endShake(of: model)

		#expect(model.touchID == .paused(.inBackground))
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
		#expect(keys.contexts.count == 1)
	}

	@Test func eachWrongFingerShakesOnceAndListensAgainUntilMacOSLocksTouchID() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)

		for miss in 1 ... 4 {
			#expect(await touch(model))
			#expect(model.shake == AppModel.Shake(count: miss, isRunning: true))
			await endShake(of: model)
		}
		keys.reply(with: .lockout)
		keys.whileLoading { keys.becomes(.lockedOut) }
		#expect(await touch(model))

		#expect(model.touchID == .lockedOut)
		#expect(model.shake == AppModel.Shake(count: 4, isRunning: false))
		#expect(await shaking.requested == Array(repeating: .milliseconds(400), count: 4))
		#expect(keys.contexts.count == 5)
		#expect(Set(keys.contexts.map(ObjectIdentifier.init)).count == 5)
		for _ in 0 ..< 200 { await Task.yield() }
		#expect(await shaking.sleeping == 0)
		#expect(model.touchID == .lockedOut)
		#expect(keys.contexts.count == 5)
	}

	@Test func aWrongFingerThatLocksTouchIDOutShakesOnceAndSaysSo() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		keys.whileLoading { keys.becomes(.lockedOut) }

		#expect(await touch(model))

		#expect(model.shake == AppModel.Shake(count: 1, isRunning: true))
		#expect(model.touchID == .lockedOut)
		await endShake(of: model)
		#expect(model.touchID == .lockedOut)
		#expect(model.shake.count == 1)
		#expect(keys.contexts.count == 1)
		#expect(model.failure == nil)
	}

	@Test func aWrongPasswordShakesAndTouchIDListensAgainOnlyWhenTheShakeEnds() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try #require(model.touchID.listeningContext)

		await model.submit(password: "a guess")

		#expect(model.failure == .wrongPassword)
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: true))
		#expect(model.touchID == .paused(.shaking))
		#expect(isInvalidated(first))
		#expect(await !touch(model))
		await endShake(of: model)
		#expect(await shaking.requested == [.milliseconds(400)])
		let second = try #require(model.touchID.listeningContext)
		#expect(second !== first)
		#expect(keys.contexts.isEmpty)
	}

	@Test func eachWrongPasswordShakesOnce() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }

		for attempt in 1 ... 3 {
			await model.submit(password: "a guess")
			#expect(model.shake == AppModel.Shake(count: attempt, isRunning: true))
			await endShake(of: model)
		}

		#expect(model.shake == AppModel.Shake(count: 3, isRunning: false))
		#expect(await shaking.requested == Array(repeating: .milliseconds(400), count: 3))
	}

	@Test func aPasswordCheckThatFailsForAnotherReasonDoesNotShake() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.removeItem(at: AppLock.databaseFile(in: directory))

		await model.submit(password: workspacePassword)

		#expect(model.failure == .unexpected("The notes database is missing."))
		#expect(model.shake == AppModel.Shake())
		#expect(model.touchID.listeningContext != nil)
		#expect(await shaking.started == 0)
	}

	@Test func aShakeAskedForWhileOneRunsIsIgnored() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		await touch(model)
		try #require(model.shake == AppModel.Shake(count: 1, isRunning: true))

		await model.submit(password: "a guess")
		await model.submit(password: "another guess")

		#expect(model.failure == .wrongPassword)
		#expect(model.shake == AppModel.Shake(count: 1, isRunning: true))
		#expect(model.touchID == .paused(.shaking))
		await settle { await shaking.sleeping == 1 }
		#expect(await shaking.started == 1)
		await endShake(of: model)
		#expect(model.touchID.listeningContext != nil)
		await model.submit(password: "a third guess")
		#expect(model.shake == AppModel.Shake(count: 2, isRunning: true))
	}

	@Test func aShakeThatEndsWhileAPasswordIsCheckedWaitsForTheCheck() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		await touch(model)
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)
		let checking = Task { await model.submit(password: workspacePassword) }
		await settle { model.touchID == .paused(.checkingPassword) }

		await endShake(of: model)

		#expect(model.touchID == .paused(.checkingPassword))
		gate.open()
		await checking.value
		try await holding.value
		#expect(model.phase == .unlocked)
		#expect(keys.contexts.count == 1)
	}

	@Test func aClickWhileAnotherAppIsInFrontListensOnceTheAppIsBack() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)
		keys.failWrites()
		await touch(model)
		model.appResignedActive()
		try #require(model.touchID == .needsClick(after: .failure))

		model.tryTouchIDAgain()

		#expect(model.touchID == .paused(.inBackground))
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func aClickOnlyRestartsTouchIDAfterItStopped() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		model.tryTouchIDAgain()

		#expect(model.touchID.listeningContext === listening)
		keys.reply(with: .lockout)
		await touch(model)
		model.tryTouchIDAgain()
		#expect(model.touchID == .lockedOut)
	}

	@Test func aLockoutSaysSoUntilTouchIDRecovers() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .lockout)
		keys.whileLoading { keys.becomes(.lockedOut) }

		#expect(await touch(model))

		#expect(model.touchID == .lockedOut)
		#expect(model.failure == nil)
		#expect(keys.storedKey != nil)
		#expect(model.shake.count == 0)
		model.appResignedActive()
		model.appBecameActive()
		#expect(model.touchID == .lockedOut)

		keys.becomes(.available)
		keys.reply(with: .key)
		model.appResignedActive()
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
		#expect(await touch(model))
		#expect(model.phase == .unlocked)
	}

	@Test func aMacLockedOutBeforeLaunchSaysSoRightAway() async throws {
		let keys = FakeKeyStore()
		let (_, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.becomes(.lockedOut)

		let relaunched = AppModel(directory: directory, keyStore: keys)
		relaunched.start()
		relaunched.appBecameActive()

		#expect(relaunched.touchID == .lockedOut)
		await relaunched.submit(password: workspacePassword)
		#expect(relaunched.phase == .unlocked)
	}

	@Test func aCancelledAttemptWaitsForAClickAndKeepsTheKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)

		#expect(await touch(model))

		#expect(model.phase == .locked)
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(model.failure == nil)
		#expect(keys.storedKey != nil)
		model.tryTouchIDAgain()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func anAttemptCancelledOnTheWayToAnotherAppListensAgainOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		await touch(model)

		model.appResignedActive()

		#expect(model.touchID == .paused(.inBackground))
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func touchIDThatGoesAwayHidesUntilTheAppIsReturnedTo() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .unavailable)

		#expect(await touch(model))

		#expect(model.touchID == .hidden)
		#expect(model.failure == nil)
		#expect(keys.storedKey != nil)
		model.appResignedActive()
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func aKeyTouchIDCannotReadIsForgottenWithAnExplanation() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)

		#expect(await touch(model))

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("Touch ID could not read the unlock key. Unlock with your password."))
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
	}

	@Test func aKeyTouchIDCannotReadOrForgetWaitsForAClickAndEndsTheAttempt() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .failure)
		keys.failWrites()

		#expect(await touch(model))

		#expect(model.failure == .unexpected("Touch ID could not read the unlock key. Unlock with your password."))
		#expect(keys.storedKey != nil)
		#expect(model.touchID == .needsClick(after: .failure))
		#expect(keys.contexts.count == 1)
		#expect(keys.contexts.allSatisfy(isInvalidated))
	}

	@Test func aStoredKeyThatNoLongerOpensTheNotesAndCannotBeForgottenWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.plant(SymmetricKey(data: Data(repeating: 0x42, count: 32)))
		keys.failWrites()

		#expect(await touch(model))

		#expect(model.failure == .unexpected("The key saved for Touch ID no longer opens these notes. Unlock with your password."))
		#expect(keys.storedKey != nil)
		#expect(model.touchID == .needsClick(after: .failure))
		#expect(keys.contexts.allSatisfy(isInvalidated))
	}

	@Test func aStoredKeyThatNoLongerOpensTheNotesIsForgotten() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.plant(SymmetricKey(data: Data(repeating: 0x42, count: 32)))

		#expect(await touch(model))

		#expect(model.phase == .locked)
		#expect(model.failure == .unexpected("The key saved for Touch ID no longer opens these notes. Unlock with your password."))
		#expect(keys.storedKey == nil)
		#expect(model.touchID == .hidden)
		await model.submit(password: workspacePassword)
		#expect(model.phase == .unlocked)
	}

	@Test func touchIDThatCannotFindTheDatabaseKeepsTheKeyAndWaitsForAClick() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.removeItem(at: AppLock.databaseFile(in: directory))

		#expect(await touch(model))

		#expect(model.failure == .unexpected("The notes database is missing."))
		#expect(keys.storedKey != nil)
		#expect(model.touchID == .needsClick(after: .failure))
		model.appResignedActive()
		model.appBecameActive()
		#expect(model.touchID == .needsClick(after: .failure))
	}

	@Test func whileTouchIDOpensTheNotesItShowsWorkAndNothingElseRuns() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys, ["bank pin 4711", "Trip"])
		defer { try? FileManager.default.removeItem(at: directory) }
		try await turnOnTouchID(model)
		model.search = "bank pin"
		await model.runSearch()
		await model.lock()
		var seen: AppModel.TouchID?
		duringSearch.body = {
			seen = model.touchID
			await model.submit(password: "a guess")
			await model.eraseLibrary()
		}

		#expect(await touch(model))

		#expect(seen == .working)
		#expect(model.phase == .unlocked)
		#expect(model.failure == nil)
		#expect(model.groups.flatMap(\.notes).map(\.body) == ["bank pin 4711"])
		#expect(FileManager.default.fileExists(atPath: AppLock.currentFile(in: directory).path))
	}

	@Test func typingThePasswordPausesTouchIDUntilItIsChecked() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let first = try #require(model.touchID.listeningContext)
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)

		let checking = Task { await model.submit(password: "a guess") }
		await settle { model.touchID != .listening(first) }
		#expect(model.touchID == .paused(.checkingPassword))
		#expect(isInvalidated(first))
		gate.open()
		await checking.value
		try await holding.value

		#expect(model.failure == .wrongPassword)
		#expect(model.touchID == .paused(.shaking))
		await endShake(of: model)
		let second = try #require(model.touchID.listeningContext)
		#expect(second !== first)
		#expect(keys.contexts.isEmpty)
	}

	@Test func aWrongPasswordCheckedAfterLeavingTheAppListensOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		let checking = Task { await model.submit(password: "a guess") }
		await settle { model.touchID == .paused(.checkingPassword) }

		model.appResignedActive()
		gate.open()
		await checking.value
		try await holding.value
		await endShake(of: model)

		#expect(model.touchID == .paused(.inBackground))
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func theRightPasswordUnlocksWithoutAskingTouchID() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		await model.submit(password: workspacePassword)

		#expect(model.phase == .unlocked)
		#expect(model.touchID == .hidden)
		#expect(isInvalidated(listening))
		#expect(keys.contexts.isEmpty)
	}

	@Test func aWrongPasswordAfterAnAttemptTheOSEndedShakesAndStillWaits() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		await touch(model)

		await model.submit(password: "a guess")

		#expect(model.failure == .wrongPassword)
		#expect(model.shake.count == 1)
		#expect(model.touchID == .needsClick(after: .cancel))
		await endShake(of: model)
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(keys.contexts.count == 1)
	}

	@Test func checkingAPasswordAfterTouchIDStopsKeepsTouchIDStopped() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		await touch(model)
		try #require(model.touchID == .needsClick(after: .cancel))
		var seen: [AppModel.TouchID] = []
		let gate = Gate()
		defer { gate.open() }
		let holding = Task.detached { try await BlockingWork.run { gate.hold() } }
		try await gate.untilHolding()
		try #require(gate.isHolding)

		let checking = Task { await model.submit(password: "a guess") }
		for _ in 0 ..< 200 {
			await Task.yield()
			seen.append(model.touchID)
		}
		gate.open()
		await checking.value
		try await holding.value

		#expect(model.failure == .wrongPassword)
		#expect(seen.allSatisfy { $0 == .needsClick(after: .cancel) })
		#expect(model.touchID == .needsClick(after: .cancel))
		#expect(keys.contexts.count == 1)
	}

	@Test func aNewLockScreenListensEvenAfterTouchIDStoppedOnTheLastOne() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		await touch(model)
		await model.submit(password: workspacePassword)
		try #require(model.phase == .unlocked)

		await model.lock()

		#expect(model.touchID.listeningContext != nil)
	}

	@Test func aNewLockScreenSaysTouchIDIsLockedWhileTheMacKeepsItLocked() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .lockout)
		keys.whileLoading { keys.becomes(.lockedOut) }
		await touch(model)
		await model.submit(password: workspacePassword)
		try #require(model.phase == .unlocked)

		await model.lock()

		#expect(model.touchID == .lockedOut)
	}

	@Test func aNewLockScreenWithAnotherAppInFrontListensOnlyOnReturn() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .cancel)
		await touch(model)
		await model.submit(password: workspacePassword)
		try #require(model.phase == .unlocked)
		model.appResignedActive()

		await model.lock()

		#expect(model.touchID == .paused(.inBackground))
		model.appBecameActive()
		#expect(model.touchID.listeningContext != nil)
	}

	@Test func aPasswordUnlockDuringTheTouchLeavesTheLibraryAlone() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.whileLoading { @MainActor in
			await model.submit(password: workspacePassword)
			if let id = model.notes.first?.id { model.edit(id, "typed after the password unlock") }
		}

		#expect(await touch(model))

		#expect(model.phase == .unlocked)
		#expect(model.notes.first?.body == "typed after the password unlock")
		#expect(model.touchID == .hidden)
	}

	@Test func turningTouchIDOffOnTheLockScreenStopsListening() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		model.disableBiometricUnlock()

		#expect(model.touchID == .hidden)
		#expect(isInvalidated(listening))
		#expect(keys.storedKey == nil)
	}

	@Test func turningTouchIDOffForgetsTheKey() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await library(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await turnOnTouchID(model)

		model.disableBiometricUnlock()

		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		await model.lock()
		#expect(model.touchID == .hidden)
	}

	@Test func aNewLibraryForgetsTheKeyOfTheOneBeforeIt() async throws {
		let keys = FakeKeyStore()
		keys.plant(SymmetricKey(data: Data(repeating: 0x42, count: 32)))
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		model.start()
		model.appBecameActive()
		#expect(model.isBiometricUnlockEnabled)
		#expect(model.touchID == .hidden)

		await model.submit(password: "fresh start")
		#expect(model.phase == .unlocked)
		#expect(keys.storedKey == nil)
		#expect(!model.isBiometricUnlockEnabled)
		await model.lock()

		#expect(model.touchID == .hidden)
	}

	@Test func aSetUpThatFindsAnotherLibraryKeepsItsKey() async throws {
		let keys = FakeKeyStore()
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let model = AppModel(directory: directory, makeParameters: { .fast }, keyStore: keys)
		model.start()
		let other = try await Unlock.setUp(password: "other instance", in: directory, makeParameters: { .fast })
		await other.store.close()
		let otherKey = try await Task.detached { try Unlock.localDbKey(password: "other instance", parameters: .fast) }.value
		try keys.save(otherKey)

		await model.submit(password: "correct horse")

		#expect(model.phase == .locked)
		#expect(keys.storedKey == otherKey)
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
		#expect(await model.enableBiometricUnlock(password: workspacePassword) != nil)
		#expect(keys.storedKey == nil)
	}

	@Test func theKeyStoreReadsOnlyThroughTheContextOfAGlyphInTheWindow() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		keys.reply(with: .miss)
		var glyphs: [PairedGlyph] = []

		for _ in 0 ..< 3 {
			let glyph = try #require(PairedGlyph(listeningFor: model))
			glyphs.append(glyph)
			await model.listen(through: glyph.view)
			await endShake(of: model)
		}

		#expect(keys.contexts.count == 3)
		for (context, glyph) in zip(keys.contexts, glyphs) {
			#expect(context === glyph.view.context)
			#expect(glyph.view.window === glyph.window)
		}
		#expect(keys.contexts.allSatisfy(isInvalidated))
	}

	@Test func aGlyphPairedWithAnotherContextStartsNothing() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		await model.listen(through: PairedGlyph(LAContext()).view)

		#expect(keys.contexts.isEmpty)
		#expect(model.touchID.listeningContext === listening)
		#expect(model.phase == .locked)
	}

	@Test func aGlyphOutsideAWindowStartsNothing() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let listening = try #require(model.touchID.listeningContext)

		await model.listen(through: PairedGlyph(listening, inWindow: false).view)

		#expect(keys.contexts.isEmpty)
		#expect(model.phase == .locked)
	}

	@Test func aGlyphForAnAttemptThatEndedStartsNothing() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let stale = try #require(PairedGlyph(listeningFor: model))
		model.appResignedActive()
		model.appBecameActive()

		await model.listen(through: stale.view)

		#expect(keys.contexts.isEmpty)
		#expect(model.touchID.listeningContext != nil)
		#expect(model.phase == .locked)
	}

	@Test func aGlyphStartsOneReadAtATime() async throws {
		let keys = FakeKeyStore()
		let (model, directory) = try await lockedWithTouchID(keys)
		defer { try? FileManager.default.removeItem(at: directory) }
		let glyph = try #require(PairedGlyph(listeningFor: model))
		keys.whileLoading { @MainActor in
			keys.whileLoading {}
			await model.listen(through: glyph.view)
		}

		await model.listen(through: glyph.view)

		#expect(keys.contexts.count == 1)
		#expect(model.phase == .unlocked)
	}
}
