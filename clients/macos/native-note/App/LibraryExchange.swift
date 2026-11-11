import AppKit
import NativeNoteKit
import Observation
import UniformTypeIdentifiers

@Observable final class LibraryExchange {
	enum Sheet: Identifiable {
		case export
		case passphrase

		var id: Self { self }
	}

	private struct ExportChoice {
		let passphrase: String?
	}

	let model: AppModel
	var isExporting = false
	private var chosenExport: ExportChoice?
	static let window = "library"
	/// Brings the library window back after it closed; set by its view, which can open windows.
	@ObservationIgnored var showWindow: (() -> Void)?
	/// Swapped by tests, which must not show a panel.
	@ObservationIgnored var presentPanel: @MainActor (NSSavePanel, @escaping (URL) -> Void) -> Void = LibraryExchange.run
	private(set) var pendingImport: URL?
	private(set) var isImporting = false
	var lastImport: ImportSummary?

	init(model: AppModel) {
		self.model = model
	}

	var sheet: Sheet? {
		if isExporting { return .export }
		if pendingImport != nil { return .passphrase }
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

	/// The library's commands wait for it to show, past unlock and the first-run sync step.
	var acceptsCommands: Bool {
		showsLibrary && sheet == nil
	}

	var canExchange: Bool {
		showsLibrary && isIdle
	}

	var canSync: Bool {
		acceptsCommands && model.syncStatus.server != nil && model.syncStatus.phase != .syncing
	}

	private var showsLibrary: Bool {
		model.phase == .unlocked && !model.isOnboarding
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
		}
	}

	/// The library's commands bring a closed window back first, as Notes does.
	func newNote() {
		showWindow?()
		Task { await model.createNote() }
	}

	func searchNotes() {
		showWindow?()
		Task { focusSearch() }
	}

	func startExport() {
		showWindow?()
		isExporting = true
	}

	/// The list's search lives in the window's toolbar, which AppKit focuses as Notes and Mail do.
	func focusSearch(in window: NSWindow? = NSApp.mainWindow) {
		window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
	}

	static let encryptedExport = UTType(filenameExtension: "nnexport", conformingTo: .data) ?? .data

	func chooseExport(passphrase: String?) {
		chosenExport = ExportChoice(passphrase: passphrase)
		isExporting = false
	}

	/// A window shows one sheet at a time, so the save panel waits for the export sheet to close.
	func sheetClosed() {
		guard let choice = chosenExport else { return }
		chosenExport = nil
		guard showsLibrary else { return }
		let passphrase = choice.passphrase
		let panel = NSSavePanel()
		panel.nameFieldStringValue = passphrase == nil ? "Native Note.zip" : "Native Note.nnexport"
		panel.allowedContentTypes = [passphrase == nil ? .zip : Self.encryptedExport]
		presentPanel(panel) { [model] url in Task { await model.exportLibrary(to: url, passphrase: passphrase) } }
	}

	func chooseImport() {
		showWindow?()
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		panel.allowedContentTypes = [.zip, Self.encryptedExport]
		presentPanel(panel) { url in Task { await self.receive(url) } }
	}

	/// Attached to the library window, as Apple apps attach their save and open panels.
	private static func run(_ panel: NSSavePanel, chosen: @escaping (URL) -> Void) {
		guard let window = NSApp.mainWindow ?? NSApp.keyWindow else {
			if panel.runModal() == .OK, let url = panel.url { chosen(url) }
			return
		}
		panel.beginSheetModal(for: window) { response in
			guard response == .OK, let url = panel.url else { return }
			chosen(url)
		}
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
