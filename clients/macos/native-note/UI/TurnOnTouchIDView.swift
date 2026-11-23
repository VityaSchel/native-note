import NativeNoteKit
import SwiftUI

struct TurnOnTouchIDView: View {
	let turnOn: (String) async -> AppModel.Failure?
	let done: () -> Void
	var touchID = TouchIDControls()
	var announce: (AttributedString) -> Void = VoiceOver.post

	@State private var form = TurnOnTouchIDForm()
	@FocusState private var typing: Bool

	var body: some View {
		SheetScaffold(
			title: "Turn On Touch ID Unlock",
			explanation: awaitsTouch ? nil : "Enter your password to unlock with Touch ID instead.",
			error: awaitsTouch ? nil : form.inlineMessage,
			working: form.working && !awaitsTouch,
			width: 380,
			reservesError: !awaitsTouch
		) {
			if awaitsTouch {
				TouchIDStatus(controls: touchID, listeningLine: Self.touchIDLine, glyphLabel: Self.touchIDLabel) { announce(AttributedString($0)) }
					.frame(maxWidth: .infinity)
			} else {
				Form {
					SecureField("Password:", text: $form.password)
						.focused($typing)
						.onSubmit(send)
						.disabled(form.working)
				}
				.formStyle(.columns)
			}
		} buttons: {
			Button("Cancel", role: .cancel, action: cancel)
				.keyboardShortcut(.cancelAction)
				.disabled(form.working && !awaitsTouch)
			if !awaitsTouch {
				Button("Continue", action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canSubmit)
					.busyAccessibilityValue(form.working)
			}
		} announce: { announce($0) }
		.defaultFocus($typing, true)
		.onDisappear(perform: touchID.cancel)
	}

	var awaitsTouch: Bool {
		form.working && touchID.state != .hidden
	}

	static let touchIDLine = "Touch ID to finish turning on Touch ID unlock."
	static let touchIDLabel = "Touch ID to turn on Touch ID unlock"

	private func cancel() {
		guard awaitsTouch else { return done() }
		touchID.cancel()
	}

	private func send() {
		guard let password = form.submit() else { return }
		Task {
			let failure = await turnOn(password)
			form.finish(failure)
			if failure == nil { done() }
		}
	}
}

#Preview("Turn on Touch ID") {
	TurnOnTouchIDView(turnOn: { _ in nil }, done: {})
}
