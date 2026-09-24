struct ExportForm {
	var encrypts = true
	var passphrase = ""
	var confirmation = ""

	var mismatched: Bool {
		encrypts && !confirmation.isEmpty && passphrase != confirmation
	}

	var canExport: Bool {
		!encrypts || (!passphrase.isEmpty && passphrase == confirmation)
	}

	var passphraseToUse: String? {
		encrypts ? passphrase : nil
	}
}
