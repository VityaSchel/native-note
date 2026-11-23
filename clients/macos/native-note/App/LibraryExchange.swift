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
	@ObservationIgnored var showWindow: (() -> Void)?
	@ObservationIgnored var presentPanel: @MainActor (NSSavePanel, @escaping (URL) -> Void) -> Void = LibraryExchange.presentAttachedToWindow
	@ObservationIgnored var closePanel: @MainActor (NSSavePanel) -> Void = LibraryExchange.cancelIfShown
	@ObservationIgnored private weak var shownPanel: NSSavePanel?
	@ObservationIgnored var sync: () async -> AppModel.SyncStatus
	@ObservationIgnored var syncAnnouncements = SyncAnnouncements.shared
	@ObservationIgnored var announce: (String) -> Void = VoiceOver.announce
	var focusesSearch = false
	private(set) var pendingImport: URL?
	private(set) var isImporting = false
	var lastImport: ImportSummary?

	init(model: AppModel) {
		self.model = model
		sync = model.statusAfterSyncing
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
		model.screen == .library
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

	func newNote() {
		showWindow?()
		Task { await model.createNote() }
	}

	func syncNow() async {
		if let outcome = await syncAnnouncements.syncNow(sync) { announce(outcome) }
	}

	func searchNotes() {
		showWindow?()
		focusesSearch = true
	}

	func startExport() {
		showWindow?()
		isExporting = true
	}

	func lock() {
		if let shownPanel { closePanel(shownPanel) }
		shownPanel = nil
		isExporting = false
		chosenExport = nil
		pendingImport = nil
		focusesSearch = false
	}

	static let encryptedExport = UTType(filenameExtension: "nnexport", conformingTo: .data) ?? .data

	func chooseExport(passphrase: String?) {
		chosenExport = ExportChoice(passphrase: passphrase)
		isExporting = false
	}

	func presentSavePanelOnceSheetCloses() {
		guard let choice = chosenExport else { return }
		chosenExport = nil
		guard showsLibrary else { return }
		let passphrase = choice.passphrase
		let panel = NSSavePanel()
		panel.nameFieldStringValue = passphrase == nil ? "Native Note.zip" : "Native Note.nnexport"
		panel.allowedContentTypes = [passphrase == nil ? .zip : Self.encryptedExport]
		present(panel) { [model] url in Task { await model.exportLibrary(to: url, passphrase: passphrase) } }
	}

	func chooseImport() {
		showWindow?()
		let panel = NSOpenPanel()
		panel.canChooseDirectories = false
		panel.allowedContentTypes = [.zip, Self.encryptedExport]
		present(panel) { url in Task { await self.receive(url) } }
	}

	private func present(_ panel: NSSavePanel, chosen: @escaping (URL) -> Void) {
		shownPanel = panel
		presentPanel(panel, chosen)
	}

	private static func cancelIfShown(_ panel: NSSavePanel) {
		guard panel.isVisible || panel.sheetParent != nil else { return }
		panel.cancel(nil)
	}

	private static func presentAttachedToWindow(_ panel: NSSavePanel, chosen: @escaping (URL) -> Void) {
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
			await importLibrary(from: url, passphrase: nil)
		}
	}

	func importPending(passphrase: String) async {
		guard let url = pendingImport, !isImporting else { return }
		if passphraseRefused { model.dismissFailure() }
		await importLibrary(from: url, passphrase: passphrase)
		guard !passphraseRefused else { return }
		pendingImport = nil
	}

	private func importLibrary(from url: URL, passphrase: String?) async {
		isImporting = true
		defer { isImporting = false }
		lastImport = await model.importLibrary(from: url, passphrase: passphrase)
	}
}
