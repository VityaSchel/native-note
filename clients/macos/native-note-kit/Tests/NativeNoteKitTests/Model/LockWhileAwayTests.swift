import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LockWhileAwayTests {
	private let alarm = Alarm()

	@Test func goingAwayLocksAnUnlockedLibrary() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["private"])

		model.lockWhileAway()
		await settle { model.phase == .locked && model.store == nil }

		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty && model.store == nil)
	}

	@Test func goingAwayWhileThePasswordIsCheckedLocksAgainOnceItOpens() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: ["private"])
		await model.lock()

		let unlocking = Task { await model.unlock(password: workspacePassword) }
		await settle { model.isCheckingPassword }
		try #require(model.isCheckingPassword)
		model.lockWhileAway()
		await unlocking.value

		#expect(model.phase == .locked)
		#expect(model.notes.isEmpty && model.store == nil)
		await model.unlock(password: workspacePassword)
		#expect(model.phase == .unlocked)
		#expect(model.notes.map(\.body) == ["private"])
	}

	@Test func goingAwayBeforeAnUnlockStartsLeavesItAlone() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		model.lockWhileAway()
		await model.unlock(password: workspacePassword)

		#expect(model.phase == .unlocked)
	}
}
