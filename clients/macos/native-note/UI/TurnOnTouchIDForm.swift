import NativeNoteKit

struct TurnOnTouchIDForm {
	var password = "" {
		didSet { if password != oldValue, failure == .wrongPassword { failure = nil } }
	}

	private(set) var working = false
	private(set) var failure: AppModel.Failure?

	var canSubmit: Bool {
		!password.isEmpty && !working
	}

	var inlineMessage: String? {
		failure?.inlineMessage(wrongPassword: "Wrong password.")
	}

	mutating func submit() -> String? {
		guard canSubmit else { return nil }
		failure = nil
		working = true
		return password
	}

	mutating func finish(_ failure: AppModel.Failure?) {
		working = false
		if failure == .wrongPassword { password = "" }
		self.failure = failure
	}
}
