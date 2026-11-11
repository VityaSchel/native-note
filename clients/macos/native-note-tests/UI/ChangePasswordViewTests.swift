import AppKit
import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
private final class Calls {
	var changes: [[String]] = []
	var done = 0
}

@MainActor
struct ChangePasswordViewTests {
	private func offscreen(_ calls: Calls, replying failure: AppModel.Failure? = nil) -> OffscreenWindow<ChangePasswordView> {
		OffscreenWindow(
			ChangePasswordView(turnsTouchIDOff: false, change: { current, new in
				calls.changes.append([current, new])
				return failure
			}, done: { calls.done += 1 })
		)
	}

	private func field(_ placeholder: String, in offscreen: OffscreenWindow<ChangePasswordView>) throws -> NSSecureTextField {
		try #require(offscreen.secureField(placeholder))
	}

	private func type(_ text: String, into placeholder: String, of offscreen: OffscreenWindow<ChangePasswordView>) throws -> NSSecureTextField {
		let field = try field(placeholder, in: offscreen)
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	@Test func returnChangesThePasswordOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls)
		defer { offscreen.close() }

		_ = try type("old password", into: "Current Password:", of: offscreen)
		_ = try type("new password", into: "New Password:", of: offscreen)
		let confirmation = try type("new password", into: "Verify:", of: offscreen)
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.changes == [["old password", "new password"]])
		#expect(calls.done == 1)
	}

	@Test func aChangeThatTurnsTouchIDOffOffersItAgainWithTheNewPassword() async throws {
		let calls = Calls()
		var offered: [String] = []
		let offscreen = OffscreenWindow(
			ChangePasswordView(
				turnsTouchIDOff: true,
				change: { current, new in
					calls.changes.append([current, new])
					return nil
				},
				offerTouchID: { password in
					offered.append(password)
					return nil
				},
				done: { calls.done += 1 }
			)
		)
		defer { offscreen.close() }

		_ = try type("old password", into: "Current Password:", of: offscreen)
		_ = try type("new password", into: "New Password:", of: offscreen)
		try type("new password", into: "Verify:", of: offscreen).currentEditor()?.insertNewline(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.changes == [["old password", "new password"]])
		#expect(offered == ["new password"])
		#expect(calls.done == 1)
	}

	@Test func aChangeWithTouchIDOffClosesWithoutOffering() async throws {
		let calls = Calls()
		var offered: [String] = []
		let offscreen = OffscreenWindow(
			ChangePasswordView(turnsTouchIDOff: false, change: { _, _ in nil }, offerTouchID: { offered.append($0); return nil }, done: { calls.done += 1 })
		)
		defer { offscreen.close() }

		_ = try type("old password", into: "Current Password:", of: offscreen)
		_ = try type("new password", into: "New Password:", of: offscreen)
		try type("new password", into: "Verify:", of: offscreen).currentEditor()?.insertNewline(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(offered.isEmpty)
		#expect(calls.done == 1)
	}

	@Test func aWrongCurrentPasswordStaysOpenWithTheFieldCleared() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls, replying: .wrongPassword)
		defer { offscreen.close() }

		let current = try type("a guess", into: "Current Password:", of: offscreen)
		_ = try type("new password", into: "New Password:", of: offscreen)
		let confirmation = try type("new password", into: "Verify:", of: offscreen)
		confirmation.currentEditor()?.insertNewline(nil)
		await offscreen.pump { !calls.changes.isEmpty && current.stringValue.isEmpty }

		#expect(calls.changes == [["a guess", "new password"]])
		#expect(current.stringValue.isEmpty)
		#expect(calls.done == 0)
	}
}
