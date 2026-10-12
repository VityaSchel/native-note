import AppKit
import NativeNoteKit
import SwiftUI

struct SyncControls {
	var status = AppModel.SyncStatus()
	var syncNow: () async -> Void = {}
	var prepareSync: (String, String) async -> Result<AppModel.RecoveryPhrase, AppModel.SyncSetupFailure> = { _, _ in .failure(.invalidServer) }
	var finishSync: ([String]) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var prepareRotation: () async -> AppModel.RecoveryPhrase? = { nil }
	var finishRotation: ([String]) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var adoptCurrentPhrase: (String) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var cancel: () -> Void = {}
}

extension SyncControls {
	init(_ model: AppModel) {
		self.init(
			status: model.syncStatus,
			syncNow: model.syncNow,
			prepareSync: model.prepareSync(server:apiKey:),
			finishSync: model.finishSync(answers:),
			prepareRotation: model.prepareRotation,
			finishRotation: model.finishRotation(answers:),
			adoptCurrentPhrase: model.adoptCurrentPhrase,
			cancel: model.cancelRecovery
		)
	}
}

struct SyncSetupView: View {
	let controls: SyncControls
	let done: () -> Void

	@State private var form: SyncSetupForm

	init(mode: SyncSetupForm.Mode, controls: SyncControls, done: @escaping () -> Void) {
		self.controls = controls
		self.done = done
		_form = State(initialValue: SyncSetupForm(mode: mode))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			content
			if let message = form.message {
				Text(message)
					.font(.callout)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack {
				if form.working {
					ProgressView().controlSize(.small)
				}
				Spacer()
				Button("Cancel", role: .cancel) {
					controls.cancel()
					done()
				}
				.keyboardShortcut(.cancelAction)
				if case .confirm = form.step {
					Button("Back") { form.back() }
				}
				Button(continueTitle, action: send)
					.keyboardShortcut(.defaultAction)
					.disabled(!form.canContinue)
			}
		}
		.textFieldStyle(.roundedBorder)
		.disabled(form.working)
		.padding(20)
		.frame(width: 440)
		.task {
			guard form.step == .preparing else { return }
			form.begin()
			form.show(await controls.prepareRotation())
		}
	}

	@ViewBuilder
	private var content: some View {
		switch form.step {
		case .preparing:
			Text("Change Recovery Phrase")
				.font(.headline)
		case .server:
			Text("Set Up Sync")
				.font(.headline)
			TextField("Server address", text: $form.server, prompt: Text(verbatim: "http://notes.example:8080"))
				.onSubmit(send)
			SecureField("API key", text: $form.apiKey)
				.onSubmit(send)
			Text("The API key is in the api-key file in the server's data directory.")
				.font(.callout)
				.foregroundStyle(.secondary)
		case let .words(phrase):
			Text("Write Down Your Recovery Phrase")
				.font(.headline)
			Text("With these words and the API key, your notes can be restored on another Mac. Native Note never keeps them, and anyone who has them can read your notes.")
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			RecoveryWords(words: phrase.words)
			Button("Copy Words") {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(phrase.words.joined(separator: " "), forType: .string)
			}
		case let .confirm(phrase):
			Text("Confirm Your Recovery Phrase")
				.font(.headline)
			ForEach(Array(phrase.checked.enumerated()), id: \.offset) { position, index in
				TextField("Word \(index + 1)", text: $form.answers[position])
					.onSubmit(send)
			}
		case .currentPhrase:
			Text("Enter the Current Recovery Phrase")
				.font(.headline)
			TextField("24 words", text: $form.currentPhrase, axis: .vertical)
				.lineLimit(3 ... 5)
		}
	}

	private var continueTitle: String {
		if case .confirm = form.step { form.confirmTitle } else { "Continue" }
	}

	private func send() {
		guard form.canContinue else { return }
		switch form.step {
		case .preparing:
			return
		case .server:
			form.begin()
			let (server, apiKey) = (form.server, form.apiKey)
			Task { form.prepared(await controls.prepareSync(server, apiKey)) }
		case .words:
			form.confirm()
		case .confirm:
			form.begin()
			let answers = form.answers
			Task {
				let failure = await (form.mode == .setUp ? controls.finishSync(answers) : controls.finishRotation(answers))
				form.finished(failure)
				if failure == nil { done() }
			}
		case .currentPhrase:
			form.begin()
			let phrase = form.currentPhrase
			Task {
				if let failure = await controls.adoptCurrentPhrase(phrase) {
					form.finished(failure)
				} else {
					form.show(await controls.prepareRotation())
				}
			}
		}
	}
}

struct RecoveryWords: View {
	static let columns = 3
	let words: [String]

	var body: some View {
		Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
			ForEach(0 ..< (words.count + Self.columns - 1) / Self.columns, id: \.self) { row in
				GridRow {
					ForEach(row * Self.columns ..< min((row + 1) * Self.columns, words.count), id: \.self) { index in
						Text(verbatim: "\(index + 1). \(words[index])")
							.monospaced()
							.fixedSize()
					}
				}
			}
		}
		.textSelection(.enabled)
		.padding(12)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
	}
}

#if DEBUG
	#Preview("Set up sync") {
		SyncSetupView(mode: .setUp, controls: SyncControls(), done: {})
	}

	#Preview("Recovery words") {
		RecoveryWords(words: (1 ... 24).map { "word\($0)" })
			.frame(width: 400)
	}
#endif
