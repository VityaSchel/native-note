import AppKit
import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
private final class Calls {
	var changes: [[String]] = []
	var done = 0
}

@MainActor @Suite(.takesFocus)
struct ChangePasswordViewTests {
	private func offscreen(_ calls: Calls, replying failure: AppModel.Failure? = nil) -> OffscreenWindow<ChangePasswordView> {
		OffscreenWindow(
			ChangePasswordView(change: { current, new in
				calls.changes.append([current, new])
				return failure
			}, done: { calls.done += 1 })
		)
	}

	@Test func returnChangesThePasswordOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls)
		defer { offscreen.close() }

		_ = try offscreen.type("old password", into: "Current Password:")
		_ = try offscreen.type("new password", into: "New Password:")
		let confirmation = try offscreen.type("new password", into: "Verify:")
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.changes == [["old password", "new password"]])
		#expect(calls.done == 1)
	}

	@Test func aWrongCurrentPasswordStaysOpenWithTheFieldCleared() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls, replying: .wrongPassword)
		defer { offscreen.close() }

		let current = try offscreen.type("a guess", into: "Current Password:")
		_ = try offscreen.type("new password", into: "New Password:")
		let confirmation = try offscreen.type("new password", into: "Verify:")
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !calls.changes.isEmpty && current.stringValue.isEmpty }

		#expect(calls.changes == [["a guess", "new password"]])
		#expect(current.stringValue.isEmpty)
		#expect(calls.done == 0)
	}
}
