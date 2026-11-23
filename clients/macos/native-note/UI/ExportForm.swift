struct ExportForm {
	var encrypts = true
	var passphrase = "" {
		didSet { if passphrase != oldValue { submitted = false } }
	}

	var confirmation = "" {
		didSet { if confirmation != oldValue { submitted = false } }
	}

	private var submitted = false

	var mismatched: Bool {
		encrypts && !confirmation.isEmpty && passphrase != confirmation && (submitted || !passphrase.hasPrefix(confirmation))
	}

	var canExport: Bool {
		!encrypts || (!passphrase.isEmpty && passphrase == confirmation)
	}

	var passphraseToUse: String? {
		encrypts ? passphrase : nil
	}

	mutating func submit() -> Bool {
		submitted = true
		return canExport
	}
}
