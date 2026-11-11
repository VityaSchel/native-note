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
			turnOffSync: model.turnOffSync,
			cancel: model.cancelRecovery
		)
	}
}

struct SyncSetupView: View {
	let controls: SyncControls
	/// Runs once sync is on, before `done`, which also runs on Cancel.
	let finished: () -> Void
	let done: () -> Void
	let clipboard: RecoveryClipboard
	let announce: (String) -> Void

	@State private var form: SyncSetupForm
	@State private var revealed = false
	@FocusState private var serverFocused: Bool
	@State private var phraseTookEffect = false
	@State private var running: Task<Void, Never>?

	init(mode: SyncSetupForm.Mode, controls: SyncControls, clipboard: RecoveryClipboard = .shared, finished: @escaping () -> Void = {}, done: @escaping () -> Void) {
		self.init(form: SyncSetupForm(mode: mode), controls: controls, clipboard: clipboard, finished: finished, done: done)
	}

	init(
		form: SyncSetupForm,
		controls: SyncControls,
		clipboard: RecoveryClipboard = .shared,
		announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
		finished: @escaping () -> Void = {},
		done: @escaping () -> Void
	) {
		self.controls = controls
		self.clipboard = clipboard
		self.announce = announce
		self.finished = finished
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
		} leadingButtons: {
			Button("Cancel", role: .cancel) {
				running?.cancel()
				controls.cancel()
				done()
			}
			.keyboardShortcut(.cancelAction)
			.disabled(form.storesThePhrase)
		} buttons: {
			buttons
		}
	}

	private func unknownAnswer(_ phrase: AppModel.RecoveryPhrase) -> Int? {
		zip(phrase.checked, form.answers).first { !PhraseEntry.couldBeListWord($0.1) }.map { $0.0 + 1 }
	}

	@ViewBuilder
	private var buttons: some View {
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
		case .server where form.mode == .changeServer: "Enter this library's server and its API key, also after the server moved or its key was replaced. An empty server takes the library under new recovery words; one that holds another library is refused."
		case .server: nil
		case .words: "These words are used to encrypt your notes on your sync server. Keep them safe and never share with anyone."
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
			RecoveryWords(words: phrase.words, revealed: revealed) { revealed = true }
			Button("Copy Words") { clipboard.copy(phrase.words) }
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
			.onChange(of: unknownAnswer(phrase)) { _, number in
				if let number { announce(PhraseFields.unknownWordMessage(number)) }
			}
		case .join:
			PhraseFields(entry: $form.phrase, submit: send, announce: announce)
		case .currentPhrase:
			PhraseFields(entry: $form.currentEntry, submit: send, announce: announce)
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
					finished()
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
				finished()
				done()
			}
		case .join:
			form.begin()
			let (server, apiKey, phrase) = (form.server, form.apiKey, form.phrase)
			running = Task {
				let failure = await controls.joinSync(server, apiKey, phrase)
				form.finished(failure)
				guard failure == nil else { return }
				finished()
				done()
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

/// The words flow down each column, then across, as a list written on paper.
struct RecoveryWords: View {
	static let columns = 3
	static let rows = 8
	/// Shown blurred in place of every word until they are revealed, so the blur gives nothing away.
	static let hiddenWord = "••••••••"
	static let warning = "Make sure your screen isn't watched"
	let words: [String]
	var revealed = true
	var reveal: () -> Void = {}

	var body: some View {
		ZStack {
			if revealed {
				RecoveryColumns(words: words)
			} else {
				HStack(alignment: .top, spacing: RecoveryColumnsView.gap) {
					ForEach(0 ..< Self.columns, id: \.self) { column in
						Text(RecoveryColumnsView.lines(words.map { _ in Self.hiddenWord }, column: column).joined(separator: "\n"))
					}
				}
				.monospacedDigit()
				.lineSpacing(6)
				.fixedSize()
				.blur(radius: 7)
				.accessibilityHidden(true)
				VStack(spacing: 10) {
					Text(Self.warning)
						.font(.callout)
					Button("Reveal", action: reveal)
				}
			}
		}
		.padding(12)
		.frame(maxWidth: .infinity)
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
