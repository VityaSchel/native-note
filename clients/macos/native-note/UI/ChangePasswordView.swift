import NativeNoteKit
import SwiftUI

struct ChangePasswordView: View {
	let change: (String, String) async -> AppModel.Failure?
	let done: () -> Void

	@State private var form = ChangePasswordForm()
	@FocusState private var focus: Field?

	private enum Field {
		case current, password, confirmation
	}

	var body: some View {
		SheetScaffold(
			title: "Change Password",
			explanation: "The new password unlocks your notes on this Mac. It cannot be recovered.",
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
				.busyAccessibilityValue(form.working)
		}
		.disabled(form.working)
		.defaultFocus($focus, .current)
	}

	private func send() {
		guard let (current, new) = form.submit() else { return }
		Task {
			let failure = await change(current, new)
			form.finish(failure)
			if failure == nil { done() }
		}
	}
}

#Preview("Change password") {
	ChangePasswordView(change: { _, _ in nil }, done: {})
}
