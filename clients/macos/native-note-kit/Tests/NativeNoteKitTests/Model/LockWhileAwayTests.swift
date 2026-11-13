import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct LockWhileAwayTests {
	private let alarm = Alarm()

	@Test func goingAwayLocksAnUnlockedLibrary() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["private"])

		model.lockWhileAway()
		try await settle { model.phase == .locked && model.store == nil }

		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty && model.store == nil)
	}

	@Test func goingAwayWhileThePasswordIsCheckedLocksAgainOnceItOpens() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		try await fill(model, with: ["private"])
		await model.lock()

		let unlocking = Task { await model.unlock(password: workspacePassword) }
		try await settle { model.biometricUnlock.isCheckingPassword }
		try #require(model.biometricUnlock.isCheckingPassword)
		model.lockWhileAway()
		await unlocking.value

		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty && model.store == nil)
		await model.unlock(password: workspacePassword)
		#expect(model.phase == .unlocked)
		#expect(model.notes.map(\.body) == ["private"])
	}

	@Test func goingAwayBeforeAnUnlockStartsLeavesItAlone() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		await model.lock()

		model.lockWhileAway()
		await model.unlock(password: workspacePassword)

		#expect(model.phase == .unlocked)
	}
}
