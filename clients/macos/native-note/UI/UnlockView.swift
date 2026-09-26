import NativeNoteKit
import SwiftUI

struct UnlockView: View {
	let isSetup: Bool
	let failure: AppModel.Failure?
	let submit: (String) async -> Void
	let dismissFailure: () -> Void
	var unlockWithBiometrics: (() async -> Void)?
	var eraseLibrary: (() -> Void)?

	@State private var form = UnlockForm()
	@State private var confirmingErase = false

	var body: some View {
		VStack(spacing: 16) {
			Text(isSetup ? "Set an unlock password" : "Native Note")
				.font(.title2.weight(.semibold))

			if isSetup {
				Text("Notes are encrypted with this password. It cannot be recovered.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
			}

			SecureField("Password", text: $form.password)
				.textFieldStyle(.roundedBorder)
				.onSubmit(send)

			if isSetup {
				SecureField("Confirm password", text: $form.confirmation)
					.textFieldStyle(.roundedBorder)
					.onSubmit(send)
			}

			if let inlineMessage = form.inlineMessage(for: failure) {
				Text(inlineMessage)
					.font(.callout)
					.foregroundStyle(.red)
			}

			HStack {
				Button(isSetup ? "Create" : "Unlock", action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canSubmit)
				if let unlockWithBiometrics, !isSetup {
					Button("Unlock with Touch ID", systemImage: "touchid") {
						guard form.begin() else { return }
						Task {
							await unlockWithBiometrics()
							form.finish()
						}
					}
					.disabled(form.working)
				}
			}

			if form.working {
				ProgressView().controlSize(.small)
			}

			if eraseLibrary != nil, !isSetup {
				Button("Forgot password?") { confirmingErase = true }
					.buttonStyle(.link)
					.disabled(form.working)
			}
		}
		.confirmationDialog(Self.eraseTitle, isPresented: $confirmingErase) {
			Button(Self.eraseAction, role: .destructive) { eraseLibrary?() }
		} message: {
			Text(Self.eraseMessage)
		}
		.padding(32)
		.frame(width: 360)
		.failureAlert(failure, dismiss: dismissFailure)
	}

	static let eraseTitle = "Erase all notes and start over?"
	static let eraseAction = "Erase Notes"
	static let eraseMessage = "Without the password these notes cannot be recovered. Erasing deletes every note on this Mac and returns to setup."

	private func send() {
		guard let password = form.submit(confirming: isSetup) else { return }
		Task {
			await submit(password)
			form.finish()
		}
	}
}

#Preview("Unlock") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {})
}

#Preview("Unlock with Touch ID") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {}, unlockWithBiometrics: {})
}

#Preview("Unlock, forgotten password") {
	UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in }, dismissFailure: {}, eraseLibrary: {})
}

#Preview("Unlock, wrong password") {
	UnlockView(isSetup: false, failure: .wrongPassword, submit: { _ in }, dismissFailure: {})
}

#Preview("Unlock, internal failure") {
	UnlockView(
		isSetup: false,
		failure: .unexpected("The notes database could not be opened. unable to open database file"),
		submit: { _ in },
		dismissFailure: {}
	)
}

#Preview("Locked, edits not saved") {
	UnlockView(
		isSetup: false,
		failure: .unsaved("disk I/O error"),
		submit: { _ in },
		dismissFailure: {}
	)
}

#Preview("First run") {
	UnlockView(isSetup: true, failure: nil, submit: { _ in }, dismissFailure: {})
}
