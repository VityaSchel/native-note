import AppKit
import NativeNoteKit
import SwiftUI

struct SyncControls {
	var status = AppModel.SyncStatus()
	var syncNow: () async -> Void = {}
	var prepareSync: (String, String) async -> Result<AppModel.SyncSetupStart, AppModel.SyncSetupFailure> = { _, _ in .failure(.invalidServer) }
	var finishSync: ([String]) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var joinSync: (String, String, PhraseEntry) async -> AppModel.SyncSetupFailure? = { _, _, _ in nil }
	var prepareRotation: () async -> AppModel.RecoveryPhrase? = { nil }
	var finishRotation: ([String]) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var adoptCurrentPhrase: (String) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var changeAPIKey: (String) async -> AppModel.SyncSetupFailure? = { _ in nil }
	var turnOffSync: () async -> Bool = { false }
	var cancel: () -> Void = {}
}

extension SyncControls {
	init(_ model: AppModel) {
		self.init(
			status: model.syncStatus,
			syncNow: model.syncNow,
			prepareSync: model.prepareSync(server:apiKey:),
			finishSync: model.finishSync(answers:),
			joinSync: model.joinSync(server:apiKey:phrase:),
			prepareRotation: model.prepareRotation,
			finishRotation: model.finishRotation(answers:),
			adoptCurrentPhrase: model.adoptCurrentPhrase,
			changeAPIKey: model.changeAPIKey,
			turnOffSync: model.turnOffSync,
			cancel: model.cancelRecovery
		)
	}
}

struct SyncSetupView: View {
	let controls: SyncControls
	let done: () -> Void
	let clipboard: RecoveryClipboard

	@State private var form: SyncSetupForm
	@State private var copied = false
	@FocusState private var serverFocused: Bool
	@State private var phraseTookEffect = false
	@State private var running: Task<Void, Never>?

	init(mode: SyncSetupForm.Mode, controls: SyncControls, clipboard: RecoveryClipboard = .shared, done: @escaping () -> Void) {
		self.init(form: SyncSetupForm(mode: mode), controls: controls, clipboard: clipboard, done: done)
	}

	init(
		form: SyncSetupForm,
		controls: SyncControls,
		clipboard: RecoveryClipboard = .shared,
		done: @escaping () -> Void
	) {
		self.controls = controls
		self.clipboard = clipboard
		self.done = done
		_form = State(initialValue: form)
	}

	var body: some View {
		sheet
			.textFieldStyle(.roundedBorder)
		.defaultFocus($serverFocused, true)
		.onDisappear {
			if !phraseTookEffect { clipboard.clear() }
		}
		.task {
			guard form.step == .preparing else { return }
			form.begin()
			form.show(await controls.prepareRotation())
		}
	}

	private var sheet: some View {
		SheetScaffold(title: title, explanation: explanation, error: form.message, working: form.working, width: 440) {
			content
				.disabled(form.working)
		} buttons: {
			buttons
		}
	}

	private func unknownAnswer(_ phrase: AppModel.RecoveryPhrase) -> Int? {
		zip(phrase.checked, form.answers).first { !PhraseEntry.couldBeListWord($0.1) }.map { $0.0 + 1 }
	}

	@ViewBuilder
	private var buttons: some View {
		Button("Cancel", role: .cancel) {
			running?.cancel()
			controls.cancel()
			done()
		}
		.keyboardShortcut(.cancelAction)
		.disabled(form.storesThePhrase)
		switch form.step {
		case .confirm, .join:
			Button("Back") { form.back() }
				.disabled(form.working)
		default:
			EmptyView()
		}
		Button(form.continueTitle, action: send)
			.keyboardShortcut(.defaultAction)
			.buttonStyle(.borderedProminent)
			.disabled(!form.canContinue)
	}

	private var explanation: String? {
		switch form.step {
		case .preparing: nil
		case .server where form.mode == .changeServer: "Enter where this library's server is now, or an empty server to move the library to. A server that holds another library is refused."
		case .server: nil
		case .words: "With these words and the API key, your notes can be restored on another Mac. Native Note never keeps them, and anyone who has them can read your notes."
		case let .confirm(phrase): "Enter words \(Self.list(phrase.checked.map { $0 + 1 })) from the phrase you wrote down."
		case .join: "This server already holds a library. Enter its current 24-word recovery phrase, and this Mac syncs with it."
		case .currentPhrase: "The recovery phrase was changed on another Mac. Enter its current 24 words to continue."
		}
	}

	static func list(_ numbers: [Int]) -> String {
		let names = numbers.map(String.init)
		guard let last = names.last, names.count > 1 else { return names.first ?? "" }
		return names.dropLast().joined(separator: ", ") + " and " + last
	}

	private var title: String {
		switch form.step {
		case .preparing: "Change Recovery Phrase"
		case .server: form.mode == .changeServer ? "Change Server" : "Set Up Sync"
		case .words: "Write Down Your Recovery Phrase"
		case .confirm: "Confirm Your Recovery Phrase"
		case .join: "Enter Your Recovery Phrase"
		case .currentPhrase: "Enter the Current Recovery Phrase"
		}
	}

	@ViewBuilder
	private var content: some View {
		switch form.step {
		case .preparing:
			EmptyView()
		case .server:
			Form {
				TextField("Server:", text: $form.server, prompt: Text(verbatim: "http://notes.example:8080"))
					.focused($serverFocused)
					.onSubmit(send)
				SecureField("API Key:", text: $form.apiKey)
					.onSubmit(send)
			}
			.formStyle(.columns)
		case let .words(phrase):
			RecoveryWords(words: phrase.words)
			Button("Copy Words") {
				clipboard.copy(phrase.words)
				copied = true
			}
			if copied {
				Text("Copied. The words leave the clipboard in 90 seconds.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		case let .confirm(phrase):
			Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 6) {
				ForEach(Array(phrase.checked.enumerated()), id: \.offset) { position, index in
					GridRow {
						WordNumber(index: index)
						TextField("Word \(index + 1)", text: $form.answers[position], prompt: Text(verbatim: ""))
							.foregroundStyle(PhraseEntry.couldBeListWord(form.answers[position]) ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
							.autocorrectionDisabled()
							.onSubmit(send)
					}
				}
			}
			if let unknown = unknownAnswer(phrase) {
				Text("Word \(unknown) is not in the recovery word list.")
					.font(.callout)
					.foregroundStyle(.red)
			}
		case .join:
			PhraseFields(entry: $form.phrase, submit: send)
		case .currentPhrase:
			PhraseFields(entry: $form.currentEntry, submit: send)
		}
	}

	private func send() {
		guard form.canContinue else { return }
		switch form.step {
		case .preparing:
			return
		case .server:
			form.begin()
			let (server, apiKey) = (form.server, form.apiKey)
			running = Task {
				let start = await controls.prepareSync(server, apiKey)
				guard start != .success(.reattached) else {
					form.finished(nil)
					return done()
				}
				form.prepared(start)
			}
		case .words:
			form.confirm()
		case .confirm:
			form.begin()
			let answers = form.answers
			running = Task {
				let failure = await (form.mode == .rotate ? controls.finishRotation(answers) : controls.finishSync(answers))
				form.finished(failure)
				guard failure == nil else { return }
				phraseTookEffect = true
				done()
			}
		case .join:
			form.begin()
			let (server, apiKey, phrase) = (form.server, form.apiKey, form.phrase)
			running = Task {
				let failure = await controls.joinSync(server, apiKey, phrase)
				form.finished(failure)
				if failure == nil { done() }
			}
		case .currentPhrase:
			form.begin()
			let phrase = form.currentEntry.words.joined(separator: " ")
			running = Task {
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
		Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
			ForEach(0 ..< (words.count + Self.columns - 1) / Self.columns, id: \.self) { row in
				GridRow {
					ForEach(row * Self.columns ..< min((row + 1) * Self.columns, words.count), id: \.self) { index in
						HStack(spacing: 4) {
							WordNumber(index: index)
							Text(verbatim: words[index])
								.fixedSize()
						}
						.accessibilityElement(children: .ignore)
						.accessibilityLabel(Text(verbatim: "\(index + 1). \(words[index])"))
						.accessibilityAddTraits(.isStaticText)
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

	#Preview("Join a library") {
		var form = SyncSetupForm(mode: .setUp)
		form.prepared(.success(.existingLibrary))
		return SyncSetupView(form: form, controls: SyncControls(), done: {})
	}

	#Preview("Recovery words") {
		RecoveryWords(words: (1 ... 24).map { "word\($0)" })
			.frame(width: 400)
	}
#endif
