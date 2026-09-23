import SwiftUI

struct UnlockView: View {
	let isSetup: Bool
	let failure: AppModel.Failure?
	let submit: (String) async -> Void
	let dismissFailure: () -> Void

	@State private var password = ""
	@State private var confirmation = ""
	@State private var mismatched = false
	@State private var working = false

	private var inlineMessage: String? {
		if mismatched { return "The passwords do not match." }
		if case .wrongPassword = failure { return "Wrong password." }
		return nil
	}

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

			SecureField("Password", text: $password)
				.textFieldStyle(.roundedBorder)
				.onSubmit(send)
				.onChange(of: password) { mismatched = false }

			if isSetup {
				SecureField("Confirm password", text: $confirmation)
					.textFieldStyle(.roundedBorder)
					.onSubmit(send)
					.onChange(of: confirmation) { mismatched = false }
			}

			if let inlineMessage {
				Text(inlineMessage)
					.font(.callout)
					.foregroundStyle(.red)
			}

			Button(isSetup ? "Create" : "Unlock", action: send)
				.keyboardShortcut(.defaultAction)
				.disabled(password.isEmpty || working)

			if working {
				ProgressView().controlSize(.small)
			}
		}
		.padding(32)
		.frame(width: 360)
		.failureAlert(failure, dismiss: dismissFailure)
	}

	private func send() {
		guard !password.isEmpty, !working else { return }
		guard !isSetup || password == confirmation else {
			mismatched = true
			return
		}

		mismatched = false
		working = true
		Task {
			await submit(password)
			working = false
			password = ""
			confirmation = ""
		}
	}
}

#Preview("Unlock") {
	UnlockView(isSetup: false, failure: nil, submit: { _ in }, dismissFailure: {})
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
