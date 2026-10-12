import NativeNoteKit

/// Setup and rotation share the words and the check; setup starts at the server, rotation at new words.
struct SyncSetupForm {
	enum Mode {
		case setUp
		case rotate
	}

	enum Step: Equatable {
		case preparing
		case server
		case words(AppModel.RecoveryPhrase)
		case confirm(AppModel.RecoveryPhrase)
		case currentPhrase
	}

	let mode: Mode
	var step: Step
	var server = ""
	var apiKey = ""
	var answers = ["", "", ""]
	var currentPhrase = ""
	private(set) var working = false
	private(set) var message: String?

	init(mode: Mode) {
		self.mode = mode
		step = mode == .setUp ? .server : .preparing
	}

	var canContinue: Bool {
		guard !working else { return false }
		return switch step {
		case .preparing: false
		case .server: !server.isEmpty && !apiKey.isEmpty
		case .words: true
		case .confirm: answers.allSatisfy { !$0.isEmpty }
		case .currentPhrase: !currentPhrase.isEmpty
		}
	}

	var confirmTitle: String {
		mode == .setUp ? "Turn On Sync" : "Change Phrase"
	}

	mutating func begin() {
		working = true
		message = nil
	}

	mutating func show(_ phrase: AppModel.RecoveryPhrase?) {
		working = false
		guard let phrase else {
			message = "Sync is not set up on this Mac."
			return
		}
		answers = ["", "", ""]
		step = .words(phrase)
	}

	mutating func prepared(_ result: Result<AppModel.RecoveryPhrase, AppModel.SyncSetupFailure>) {
		switch result {
		case let .success(phrase): show(phrase)
		case let .failure(failure): fail(failure)
		}
	}

	mutating func confirm() {
		guard case let .words(phrase) = step else { return }
		step = .confirm(phrase)
	}

	mutating func back() {
		guard case let .confirm(phrase) = step else { return }
		step = .words(phrase)
	}

	/// After the phrase went in, or after the current phrase was adopted and rotation must start over.
	mutating func finished(_ failure: AppModel.SyncSetupFailure?) {
		guard let failure else {
			working = false
			return
		}
		fail(failure)
		if failure == .rotatedElsewhere { step = .currentPhrase }
	}

	private mutating func fail(_ failure: AppModel.SyncSetupFailure) {
		working = false
		message = failure.message
	}
}
