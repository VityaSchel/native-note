import NativeNoteKit
import SwiftUI

struct ChangeAPIKeyView: View {
	let change: (String) async -> AppModel.SyncSetupFailure?
	let done: () -> Void

	@State private var apiKey = ""
	@State private var working = false
	@State private var message: String?
	@FocusState private var typing: Bool
	@State private var running: Task<Void, Never>?

	var body: some View {
		SheetScaffold(
			title: "Change API Key",
			explanation: "Enter the key from the server's api-key file after it was replaced, as when a Mac is lost. Every Mac that still syncs needs the new key.",
			error: message,
			working: working
		) {
			Form {
				SecureField("API Key:", text: $apiKey)
					.focused($typing)
					.onSubmit(send)
			}
			.formStyle(.columns)
			.disabled(working)
		} buttons: {
			Button("Cancel", role: .cancel) {
				running?.cancel()
				done()
			}
			.keyboardShortcut(.cancelAction)
			Button("Change API Key", action: send)
				.keyboardShortcut(.defaultAction)
				.disabled(apiKey.isEmpty || working)
		}
		.defaultFocus($typing, true)
	}

	private func send() {
		guard !apiKey.isEmpty, !working else { return }
		working = true
		message = nil
		let key = apiKey
		running = Task {
			let failure = await change(key)
			working = false
			message = failure?.message
			if failure == nil { done() }
		}
	}
}

#if DEBUG
	#Preview("Change API key") {
		ChangeAPIKeyView(change: { _ in .refused }, done: {})
	}
#endif
