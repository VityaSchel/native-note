import AppKit
import NativeNoteKit
import Testing

@testable import NativeNote

@MainActor
private final class Calls {
	var keys: [String] = []
	var done = 0
}

@MainActor
struct ChangeAPIKeyViewTests {
	private func offscreen(_ calls: Calls, replying failure: AppModel.SyncSetupFailure? = nil) -> OffscreenWindow<ChangeAPIKeyView> {
		OffscreenWindow(
			ChangeAPIKeyView(change: { key in
				calls.keys.append(key)
				return failure
			}, done: { calls.done += 1 })
		)
	}

	private func type(_ text: String, into offscreen: OffscreenWindow<ChangeAPIKeyView>) throws -> NSSecureTextField {
		let field = try #require(offscreen.secureField("API Key:"))
		try #require(offscreen.window.makeFirstResponder(field))
		try #require(field.currentEditor()).insertText(text)
		offscreen.pump()
		return field
	}

	@Test func returnChangesTheKeyOnceAndCloses() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls)
		defer { offscreen.close() }

		try type("0123abcd", into: offscreen).currentEditor()?.insertNewline(nil)
		await offscreen.pump { calls.done > 0 }

		#expect(calls.keys == ["0123abcd"])
		#expect(calls.done == 1)
	}

	@Test func aRefusedKeyStaysOpenAndSaysWhy() async throws {
		let calls = Calls()
		let offscreen = offscreen(calls, replying: .refused)
		defer { offscreen.close() }

		try type("0123abcd", into: offscreen).currentEditor()?.insertNewline(nil)
		await offscreen.pump { offscreen.accessibilityElements(.staticText).contains { $0.value == AppModel.SyncSetupFailure.refused.message } }

		#expect(offscreen.accessibilityElements(.staticText).contains { $0.value == AppModel.SyncSetupFailure.refused.message })
		#expect(calls.keys == ["0123abcd"])
		#expect(calls.done == 0)
	}
}
