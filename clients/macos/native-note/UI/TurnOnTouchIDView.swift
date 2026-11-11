import NativeNoteKit
import SwiftUI

struct TurnOnTouchIDView: View {
	let turnOn: (String) async -> AppModel.Failure?
	let done: () -> Void
	var touchID = TouchIDControls()
	/// After a password change, the new password goes straight to the touch, and Not Now ends it.
	var password: String?
	var declineTitle = "Cancel"

	@State private var form = TurnOnTouchIDForm()
	@FocusState private var typing: Bool

	var body: some View {
		SheetScaffold(
			title: "Turn On Touch ID Unlock",
			explanation: password != nil
				? "The new password turned Touch ID unlock off. Touch ID turns it on again."
				: awaitsTouch ? nil : "Enter your password to unlock with Touch ID instead.",
			error: awaitsTouch ? nil : form.inlineMessage,
			working: form.working && !awaitsTouch,
			width: 380
		) {
			if awaitsTouch {
				TouchIDStatus(controls: touchID, listeningLine: Self.touchIDLine, glyphLabel: Self.touchIDLabel)
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
			Button(declineTitle, role: .cancel, action: cancel)
				.keyboardShortcut(.cancelAction)
				.disabled(form.working && !awaitsTouch)
			Button("Turn On", action: send)
				.keyboardShortcut(.defaultAction)
				.disabled(!form.canSubmit)
		}
		.defaultFocus($typing, true)
		.onDisappear(perform: touchID.cancel)
		.onAppear {
			guard let password else { return }
			form.password = password
			send()
		}
	}

	var awaitsTouch: Bool {
		form.working && touchID.state != .hidden
	}

	static let touchIDLine = "Touch ID to finish turning on Touch ID unlock."
	static let touchIDLabel = "Touch ID to turn on Touch ID unlock"

	private func cancel() {
		guard awaitsTouch else { return done() }
		touchID.cancel()
		if password != nil { done() }
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
