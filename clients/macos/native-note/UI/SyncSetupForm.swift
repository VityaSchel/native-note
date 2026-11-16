import NativeNoteKit

struct SyncSetupForm {
	enum Mode {
		case setUp
		case rotate
		case changeServer
	}

	enum Step: Equatable {
		case preparing
		case server
		case words(AppModel.RecoveryPhrase)
		case confirm(AppModel.RecoveryPhrase)
		case join
		case currentPhrase
	}

	let mode: Mode
	var step: Step
	var server = ""
	var apiKey = ""
	var answers = ["", "", ""]
	var phrase = PhraseEntry()
	var currentEntry = PhraseEntry()
	private(set) var working = false
	private(set) var message: String?
	private(set) var wordsRevealed = false

	init(mode: Mode, server: String = "") {
		self.mode = mode
		self.server = server
		step = mode == .rotate ? .preparing : .server
	}

	var storesThePhrase: Bool {
		guard working, case .confirm = step else { return false }
		return true
	}

	var canContinue: Bool {
		guard !working else { return false }
		return switch step {
		case .preparing: false
		case .server: !server.isEmpty && !apiKey.isEmpty
		case .words: true
		case .confirm: answers.allSatisfy(PhraseEntry.isListWord)
		case .join: phrase.opens
		case .currentPhrase: currentEntry.opens
		}
	}

	var confirmTitle: String {
		switch mode {
		case .setUp: "Turn On Sync"
		case .rotate: "Change Phrase"
		case .changeServer: "Move Library"
		}
	}

	var continueTitle: String {
		switch step {
		case .confirm: confirmTitle
		case .join: "Turn On Sync"
		default: "Continue"
		}
	}

	mutating func begin() {
		working = true
		message = nil
	}

	private mutating func show(_ phrase: AppModel.RecoveryPhrase) {
		working = false
		answers = ["", "", ""]
		wordsRevealed = false
		step = .words(phrase)
	}

	mutating func revealWords() {
		wordsRevealed = true
	}

	mutating func rotationPrepared(_ rotation: Result<AppModel.RecoveryPhrase, AppModel.SyncSetupFailure>) {
		switch rotation {
		case let .success(phrase): show(phrase)
		case let .failure(failure): fail(failure)
		}
	}

	mutating func prepared(_ result: Result<AppModel.SyncSetupStart, AppModel.SyncSetupFailure>) {
		switch result {
		case let .success(.newLibrary(phrase)):
			show(phrase)
		case .success(.existingLibrary):
			working = false
			step = .join
		case .success(.reattached):
			working = false
		case let .failure(failure):
			fail(failure)
		}
	}

	mutating func confirm() {
		guard case let .words(phrase) = step else { return }
		step = .confirm(phrase)
	}

	mutating func back() {
		switch step {
		case let .confirm(phrase):
			step = .words(phrase)
		case .join:
			message = nil
			step = .server
		default:
			return
		}
	}

	mutating func finished(_ failure: AppModel.SyncSetupFailure?) {
		guard let failure else {
			working = false
			return
		}
		fail(failure)
		switch failure {
		case .rotatedElsewhere: step = .currentPhrase
		case .serverHasLibrary: step = .join
		case .serverHasNoLibrary: step = .server
		default: break
		}
	}

	private mutating func fail(_ failure: AppModel.SyncSetupFailure) {
		working = false
		message = failure.message
	}
}
