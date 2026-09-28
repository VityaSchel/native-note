import NativeNoteKit
import SwiftUI

struct TurnOnTouchIDView: View {
	let turnOn: (String) async -> AppModel.Failure?
	let done: () -> Void
	var touchID = TouchIDControls()

	@State private var form = TurnOnTouchIDForm()

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Turn On Touch ID Unlock")
				.font(.headline)

			if awaitsTouch {
				TouchIDStatus(controls: touchID, listeningLine: Self.touchIDLine, glyphLabel: Self.touchIDLabel)
					.frame(maxWidth: .infinity)
			} else {
				SecureField("Password", text: $form.password)
					.onSubmit(send)
					.disabled(form.working)

				if let inlineMessage = form.inlineMessage {
					Text(inlineMessage)
						.font(.callout)
						.foregroundStyle(.red)
				}
			}

			HStack {
				if form.working, !awaitsTouch {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Cancel", role: .cancel, action: cancel)
					.keyboardShortcut(.cancelAction)
					.disabled(form.working && !awaitsTouch)
				Button("Turn On", action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canSubmit)
			}
		}
		.textFieldStyle(.roundedBorder)
		.padding(20)
		.frame(width: 360)
		.onDisappear(perform: touchID.cancel)
	}

	var awaitsTouch: Bool {
		form.working && touchID.state != .hidden
	}

	static let touchIDLine = "Touch ID to finish turning on Touch ID unlock."
	static let touchIDLabel = "Touch ID to turn on Touch ID unlock"

	private func cancel() {
		if awaitsTouch { touchID.cancel() } else { done() }
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
