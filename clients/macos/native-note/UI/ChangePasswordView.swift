import NativeNoteKit
import SwiftUI

struct ChangePasswordView: View {
	let turnsTouchIDOff: Bool
	let change: (String, String) async -> AppModel.Failure?
	let done: () -> Void

	@State private var form = ChangePasswordForm()

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Change Password")
				.font(.headline)

			SecureField("Current password", text: $form.current)
				.onSubmit(send)
			SecureField("New password", text: $form.password)
				.onSubmit(send)
			SecureField("Confirm new password", text: $form.confirmation)
				.onSubmit(send)

			if let inlineMessage = form.inlineMessage {
				Text(inlineMessage)
					.font(.callout)
					.foregroundStyle(.red)
			}

			if turnsTouchIDOff {
				Text("Touch ID unlock turns off. Turn it on again after the change.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			HStack {
				if form.working {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Cancel", role: .cancel, action: done)
					.keyboardShortcut(.cancelAction)
					.disabled(form.working)
				Button("Change Password", action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canSubmit)
			}
		}
		.textFieldStyle(.roundedBorder)
		.disabled(form.working)
		.padding(20)
		.frame(width: 360)
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
	ChangePasswordView(turnsTouchIDOff: false, change: { _, _ in nil }, done: {})
}

#Preview("Change password, Touch ID on") {
	ChangePasswordView(turnsTouchIDOff: true, change: { _, _ in nil }, done: {})
}
