import AppKit
import NativeNoteKit
import Observation

@Observable final class LibraryExchange {
	enum Sheet: Identifiable {
		case export
		case passphrase
		case conflicts

		var id: Self { self }
	}

	let model: AppModel
	var isExporting = false
	private(set) var pendingImport: URL?
	private(set) var isImporting = false
	var lastImport: ImportSummary?

	init(model: AppModel) {
		self.model = model
	}

	var sheet: Sheet? {
		if isExporting { return .export }
		if pendingImport != nil { return .passphrase }
		if !model.conflicts.isEmpty { return .conflicts }
		return nil
	}

	var presentedSheet: Sheet? {
		get { sheet }
		set { if newValue == nil, let shown = sheet { dismiss(shown) } }
	}

	var showsSummary: Bool {
		get { lastImport != nil && sheet == nil }
		set { if !newValue { lastImport = nil } }
	}

	var isIdle: Bool {
		!isImporting && sheet == nil
	}

	var passphraseRefused: Bool {
		model.failure == .wrongExportPassphrase
	}

	func dismiss(_ sheet: Sheet) {
		switch sheet {
		case .export:
			isExporting = false
		case .passphrase:
			guard !isImporting else { return }
			pendingImport = nil
			if passphraseRefused { model.dismissFailure() }
		case .conflicts:
			break
		}
	}

	func chooseExport(passphrase: String?) {
		isExporting = false
		let panel = NSSavePanel()
		panel.nameFieldStringValue = passphrase == nil ? "Native Note.zip" : "Native Note.nnexport"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		Task { await model.exportLibrary(to: url, passphrase: passphrase) }
	}

	func chooseImport() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		Task { await receive(url) }
	}

	func receive(_ url: URL) async {
		guard !isImporting else { return }
		if AppModel.isEncryptedExport(at: url) {
			pendingImport = url
		} else {
			await run(url, passphrase: nil)
		}
	}

	func importPending(passphrase: String) async {
		guard let url = pendingImport, !isImporting else { return }
		if passphraseRefused { model.dismissFailure() }
		await run(url, passphrase: passphrase)
		guard !passphraseRefused else { return }
		pendingImport = nil
	}

	private func run(_ url: URL, passphrase: String?) async {
		isImporting = true
		defer { isImporting = false }
		lastImport = await model.importLibrary(from: url, passphrase: passphrase)
	}
}
