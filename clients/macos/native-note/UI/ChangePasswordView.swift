import NativeNoteKit
import SwiftUI

struct ChangePasswordView: View {
	let turnsTouchIDOff: Bool
	let change: (String, String) async -> AppModel.Failure?
	var offerTouchID: ((String) async -> AppModel.Failure?)?
	var touchID = TouchIDControls()
	let done: () -> Void

	@State private var form = ChangePasswordForm()
	@FocusState private var focus: Field?
	@State private var changedTo: String?

	private enum Field {
		case current, password, confirmation
	}

	@ViewBuilder
	var body: some View {
		if let changedTo, let offerTouchID {
			TurnOnTouchIDView(turnOn: offerTouchID, done: done, touchID: touchID, changedPassword: changedTo, declineTitle: "Not Now")
		} else {
			passwordForm
		}
	}

	private var passwordForm: some View {
		SheetScaffold(
			title: "Change Password",
			explanation: turnsTouchIDOff
				? "Touch ID unlock turns off. Turn it on again after the change."
				: "The new password unlocks your notes on this Mac. It cannot be recovered.",
			error: form.inlineMessage,
			working: form.working,
			width: 400
		) {
			Form {
				SecureField("Current Password:", text: $form.current)
					.focused($focus, equals: .current)
					.onSubmit { focus = .password }
				SecureField("New Password:", text: $form.password)
					.focused($focus, equals: .password)
					.onSubmit { focus = .confirmation }
				SecureField("Verify:", text: $form.confirmation)
					.focused($focus, equals: .confirmation)
					.onSubmit(send)
			}
			.formStyle(.columns)
		} buttons: {
			Button("Cancel", role: .cancel, action: done)
				.keyboardShortcut(.cancelAction)
				.disabled(form.working)
			Button("Change Password", action: send)
				.keyboardShortcut(.defaultAction)
				.disabled(!form.canSubmit)
		}
		.disabled(form.working)
		.defaultFocus($focus, .current)
	}

	private func send() {
		guard let (current, new) = form.submit() else { return }
		Task {
			let failure = await change(current, new)
			form.finish(failure)
			guard failure == nil else { return }
			if turnsTouchIDOff, offerTouchID != nil {
				changedTo = new
			} else {
				done()
			}
		}
	}
}

#Preview("Change password") {
	ChangePasswordView(turnsTouchIDOff: false, change: { _, _ in nil }, done: {})
}

#Preview("Change password, Touch ID on") {
	ChangePasswordView(turnsTouchIDOff: true, change: { _, _ in nil }, done: {})
}
