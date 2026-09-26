import NativeNoteKit

struct ChangePasswordForm {
	var current = "" {
		didSet { if current != oldValue, failure == .wrongPassword { failure = nil } }
	}

	var password = "" {
		didSet { if password != oldValue { mismatched = false } }
	}

	var confirmation = "" {
		didSet { if confirmation != oldValue { mismatched = false } }
	}

	private(set) var mismatched = false
	private(set) var working = false
	private(set) var failure: AppModel.Failure?

	var canSubmit: Bool {
		!current.isEmpty && !password.isEmpty && !working
	}

	var inlineMessage: String? {
		if mismatched { return "The new passwords do not match." }
		return switch failure {
		case .wrongPassword: "Wrong current password."
		case let .unexpected(reason), let .unsaved(reason): reason
		case .wrongExportPassphrase, nil: nil
		}
	}

	mutating func submit() -> (current: String, new: String)? {
		guard canSubmit else { return nil }
		guard password == confirmation else {
			mismatched = true
			return nil
		}
		failure = nil
		working = true
		return (current, password)
	}

	mutating func finish(_ failure: AppModel.Failure?) {
		working = false
		if failure == .wrongPassword { current = "" }
		self.failure = failure
	}
}
