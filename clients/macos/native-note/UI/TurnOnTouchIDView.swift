import NativeNoteKit
import SwiftUI

struct TurnOnTouchIDView: View {
	let turnOn: (String) async -> AppModel.Failure?
	let done: () -> Void

	@State private var form = TurnOnTouchIDForm()

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Turn On Touch ID Unlock")
				.font(.headline)

			SecureField("Password", text: $form.password)
				.onSubmit(send)

			if let inlineMessage = form.inlineMessage {
				Text(inlineMessage)
					.font(.callout)
					.foregroundStyle(.red)
			}

			HStack {
				if form.working {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Cancel", role: .cancel, action: done)
					.keyboardShortcut(.cancelAction)
					.disabled(form.working)
				Button("Turn On", action: send)
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
