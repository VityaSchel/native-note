import NativeNoteKit

struct UnlockForm {
	var password = "" {
		didSet {
			guard password != oldValue else { return }
			mismatched = false
			rejected = false
		}
	}

	var confirmation = "" {
		didSet { if confirmation != oldValue { mismatched = false } }
	}

	private(set) var mismatched = false
	private(set) var working = false
	private(set) var rejected = false
	private var submitted: String?

	var canSubmit: Bool {
		!password.isEmpty && !working
	}

	var inlineMessage: String? {
		mismatched ? "The passwords do not match." : nil
	}

	mutating func submit(confirming: Bool) -> String? {
		guard canSubmit else { return nil }
		guard !confirming || password == confirmation else {
			mismatched = true
			return nil
		}

		mismatched = false
		working = true
		submitted = password
		return password
	}

	mutating func finish(_ failure: AppModel.Failure?) {
		working = false
		let sent = submitted
		submitted = nil
		guard failure != .wrongPassword else {
			rejected = password == sent
			return
		}
		password = ""
		confirmation = ""
	}

	mutating func takeRejection() -> Bool {
		defer { rejected = false }
		return rejected
	}
}
