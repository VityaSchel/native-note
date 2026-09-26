import NativeNoteKit
import SwiftUI

struct UnlockView: View {
	let isSetup: Bool
	let failure: AppModel.Failure?
	let submit: (String) async -> Void
	let dismissFailure: () -> Void
	var unlockWithBiometrics: (() async -> Void)?
	var eraseLibrary: (() -> Void)?
	var hasSecureEnclave = true

	@State private var form = UnlockForm()
	@State private var confirmingErase = false
	@State private var touchingID = false

	var body: some View {
		VStack(spacing: 18) {
			Image(systemName: isSetup ? "key.shield.fill" : "lock.shield.fill")
				.font(.system(size: 56))
				.foregroundStyle(.tint)

			VStack(spacing: 6) {
				Text(isSetup ? "Set an Unlock Password" : "Native Note")
					.font(.largeTitle.bold())
				if isSetup {
					Text("Notes are encrypted with this password. It cannot be recovered.")
						.font(.callout)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}
			}

			if let setupWarning {
				Label(setupWarning, systemImage: "exclamationmark.triangle")
					.font(.callout)
					.foregroundStyle(.orange)
					.fixedSize(horizontal: false, vertical: true)
			}

			VStack(spacing: 10) {
				SecureField("Password", text: $form.password)
					.onSubmit(send)
				if isSetup {
					SecureField("Confirm Password", text: $form.confirmation)
						.onSubmit(send)
				}
			}
			.textFieldStyle(.roundedBorder)
			.controlSize(.extraLarge)

			Text(form.inlineMessage(for: failure) ?? " ")
				.font(.callout)
				.foregroundStyle(.red)
				.frame(minHeight: 18)

			VStack(spacing: 10) {
				Button(action: send) {
					working(isSetup ? "Create" : "Unlock", spinning: form.working && !touchingID)
				}
				.buttonStyle(.glassProminent)
				.keyboardShortcut(.defaultAction)
				.disabled(!form.canSubmit)

				if let unlockWithBiometrics, !isSetup {
					Button {
						guard form.begin() else { return }
						touchingID = true
						Task {
							await unlockWithBiometrics()
							touchingID = false
							form.finish()
						}
					} label: {
						working(Label("Unlock with Touch ID", systemImage: "touchid"), spinning: touchingID)
					}
					.buttonStyle(.glass)
					.disabled(form.working)
				}
			}
			.controlSize(.extraLarge)

			if eraseLibrary != nil, !isSetup {
				Button("Forgot Password?") { confirmingErase = true }
					.buttonStyle(.link)
					.disabled(form.working)
			}
		}
		.confirmationDialog(Self.eraseTitle, isPresented: $confirmingErase) {
			Button(Self.eraseAction, role: .destructive) { eraseLibrary?() }
		} message: {
			Text(Self.eraseMessage)
		}
		.frame(width: 300)
		.padding(32)
		.failureAlert(failure, dismiss: dismissFailure)
	}

	private func working(_ title: String, spinning: Bool) -> some View {
		working(Text(title), spinning: spinning)
	}

	private func working(_ label: some View, spinning: Bool) -> some View {
		ZStack {
			label.opacity(spinning ? 0 : 1)
			if spinning {
				ProgressView().controlSize(.small)
			}
		}
		.frame(maxWidth: .infinity)
	}

	var setupWarning: String? {
		isSetup && !hasSecureEnclave ? Self.noSecureEnclaveWarning : nil
	}

	static let noSecureEnclaveWarning = "This Mac has no Secure Enclave, so only this password protects your notes."
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

#Preview("First run, no Secure Enclave") {
	UnlockView(isSetup: true, failure: nil, submit: { _ in }, dismissFailure: {}, hasSecureEnclave: false)
}
