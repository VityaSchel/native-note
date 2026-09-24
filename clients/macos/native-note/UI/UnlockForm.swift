import NativeNoteKit

struct UnlockForm {
	var password = "" {
		didSet { if password != oldValue { mismatched = false } }
	}

	var confirmation = "" {
		didSet { if confirmation != oldValue { mismatched = false } }
	}

	private(set) var mismatched = false
	private(set) var working = false

	var canSubmit: Bool {
		!password.isEmpty && !working
	}

	func inlineMessage(for failure: AppModel.Failure?) -> String? {
		if mismatched { return "The passwords do not match." }
		if case .wrongPassword = failure { return "Wrong password." }
		return nil
	}

	mutating func submit(confirming: Bool) -> String? {
		guard canSubmit else { return nil }
		guard !confirming || password == confirmation else {
			mismatched = true
			return nil
		}

		mismatched = false
		working = true
		return password
	}

	mutating func finish() {
		working = false
		password = ""
		confirmation = ""
	}
}
