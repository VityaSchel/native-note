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
		return failure?.inlineMessage(wrongPassword: "Wrong current password.")
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
		if failure == nil || failure == .wrongPassword { current = "" }
		if failure == nil { (password, confirmation) = ("", "") }
		self.failure = failure
	}
}
