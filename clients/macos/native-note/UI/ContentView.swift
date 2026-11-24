import NativeNoteKit
import SwiftUI

struct ContentView: View {
	@Bindable var exchange: LibraryExchange
	@Bindable var model: AppModel
	let clipboard: RecoveryClipboard
	let announce: (String) -> Void
	let syncAnnouncements: SyncAnnouncements
	@Environment(\.undoManager) private var undoManager
	@Environment(\.openWindow) private var openWindow
	@AppStorage(EditorZoom.key) private var zoom = 1.0

	init(
		exchange: LibraryExchange,
		clipboard: RecoveryClipboard = .shared,
		announce: @escaping (String) -> Void = VoiceOver.announce,
		syncAnnouncements: SyncAnnouncements = .shared
	) {
		self.exchange = exchange
		model = exchange.model
		self.clipboard = clipboard
		self.announce = announce
		self.syncAnnouncements = syncAnnouncements
	}

	private func delete(_ id: UUID) {
		let kept = model.keepForUndo(id)
		Task {
			guard await model.delete(id), let kept, let undoManager, model.phase == .unlocked else { return }
			undoManager.beginUndoGrouping()
			offerUndo(of: UndoableDelete(kept))
			undoManager.endUndoGrouping()
		}
	}

	private func deleteAgain(_ id: UUID) {
		let undo = model.keepForUndo(id).map(UndoableDelete.init)
		undo.map(offerUndo)
		Task {
			guard await !model.delete(id), let undo else { return }
			undoManager?.removeAllActions(withTarget: undo)
		}
	}

	private func offerUndo(of deleted: UndoableDelete) {
		undoManager?.registerUndo(withTarget: deleted) { [weak undoManager, model] _ in
			MainActor.assumeIsolated {
				guard let restored = model.restore(deleted.kept) else { return }
				undoManager?.registerUndo(withTarget: model) { _ in
					MainActor.assumeIsolated { deleteAgain(restored) }
				}
				undoManager?.setActionName("Delete Note")
			}
		}
		undoManager?.setActionName("Delete Note")
	}

	var body: some View {
		screen
			.frame(minWidth: 720, minHeight: 460)
			.onAppear { exchange.showWindow = { openWindow(id: LibraryExchange.window) } }
			.onDisappear { Task { await model.flushPendingSaves() } }
			.onChange(of: model.phase) { _, phase in
				guard phase != .unlocked else { return }
				undoManager?.removeAllActions()
			}
	}

	@ViewBuilder
	private var screen: some View {
		switch model.screen {
		case .loading:
			ProgressView().onAppear { model.start() }
		case .onboarding:
			onboarding
		case .locked:
			UnlockView(
				failure: model.failure,
				submit: model.submit(password:),
				dismissFailure: model.dismissFailure,
				touchID: TouchIDControls(model),
				shake: model.shake,
				eraseLibrary: { Task { await model.eraseLibrary() } },
				announce: announce
			)
		case .library:
			library
		}
	}

	private var onboarding: some View {
		OnboardingView(
			libraryExists: model.phase == .unlocked,
			createLibrary: model.submit(password:),
			failure: model.failure,
			dismissFailure: model.dismissFailure,
			hasSecureEnclave: AppModel.hasSecureEnclave,
			touchIDAvailable: model.isBiometricUnlockAvailable,
			turnOnTouchID: model.enableBiometricUnlock(password:),
			touchID: TouchIDControls(model),
			sync: SyncControls(model),
			clipboard: clipboard,
			announce: announce,
			finish: model.finishOnboarding
		)
	}

	static func noteCount(_ count: Int) -> String {
		String(AttributedString(localized: "^[\(count) note](inflect: true)").characters)
	}

	private static let allNotes = "all"
	static let narrowestList: CGFloat = 240

	@ViewBuilder
	private var detail: some View {
		if let note = model.selectedNote {
			NoteEditor(
				text: Binding(get: { note.body }, set: { model.edit(note.id, $0, shownAt: note.v) }),
				takesFocus: model.focusesEditor == note.id,
				tookFocus: model.editorTookFocus,
				zoom: zoom,
				dateLine: NoteGrouping.editorDateLine(for: note.updated),
				spokenDateLine: NoteGrouping.spokenEditorDateLine(for: note.updated)
			)
			.id(note.id)
		} else if model.noteCount > 0 {
			ContentUnavailableView("No Note Selected", systemImage: "note.text")
		} else {
			Color.clear
		}
	}

	@ToolbarContentBuilder
	private var libraryToolbar: some ToolbarContent {
		ToolbarItemGroup {
			Button { Task { await model.createNote() } } label: {
				Label("New Note", systemImage: "square.and.pencil")
			}
			Button { model.selection.map(delete) } label: {
				Label("Delete", systemImage: "trash")
			}
			.disabled(model.selection == nil)
		}
		ToolbarSpacer(.fixed)
		ToolbarItemGroup {
			if model.syncStatus.server != nil {
				SyncButton(status: model.syncStatus, sync: model.statusAfterSyncing, announce: announce, announcements: syncAnnouncements)
			}
			Button { Task { await model.lock() } } label: {
				Label("Lock", systemImage: "lock")
			}
		}
	}

	private var library: some View {
		NavigationSplitView {
			List(selection: .constant(Optional(Self.allNotes))) {
				Label("All Notes", systemImage: "folder")
					.badge(model.noteCount)
					.tag(Self.allNotes)
			}
			.navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
		} content: {
			TimelineView(.everyMinute) { timeline in
				NoteListView(groups: model.groups, now: timeline.date, selection: $model.selection, search: $model.search, focusesSearch: $exchange.focusesSearch, yieldsFocus: model.focusesEditor != nil) { id in
					delete(id)
				}
			}
			.navigationSplitViewColumnWidth(min: Self.narrowestList, ideal: 280, max: 420)
			.navigationTitle("All Notes")
			.navigationSubtitle(Self.noteCount(model.noteCount))
			.onChange(of: model.search) { Task { await model.runSearch() } }
			.alert(exchange.lastImport?.message ?? "", isPresented: $exchange.showsSummary) {
				Button("OK") {}
			}
		} detail: {
			detail
		}
		.toolbar { libraryToolbar }
		.failureAlert(model.failure, dismiss: model.dismissFailure)
		.onChange(of: model.syncStatus.phase, initial: true) { _, phase in
			if let line = syncAnnouncements.phaseChanged(to: phase) { announce(line) }
		}
		.sheet(item: $exchange.presentedSheet, onDismiss: exchange.presentSavePanelOnceSheetCloses) { sheet in
			switch sheet {
			case .export:
				ExportSheet(export: exchange.chooseExport(passphrase:)) { exchange.dismiss(.export) }
			case .passphrase:
				ImportPassphraseSheet(refused: exchange.passphraseRefused, working: exchange.isImporting) { passphrase in
					Task { await exchange.importPending(passphrase: passphrase) }
				} cancel: {
					exchange.dismiss(.passphrase)
				}
			}
		}
	}
}

private final class UndoableDelete {
	let kept: UUID

	init(_ kept: UUID) {
		self.kept = kept
	}
}

#if DEBUG
	#Preview("Library") {
		ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes))))
			.frame(width: 980, height: 560)
	}

	#Preview("Library, edits not saved") {
		ContentView(exchange: LibraryExchange(model: .previewing(NoteGroup.samples.flatMap(\.notes), failure: .unsaved("disk I/O error"))))
			.frame(width: 980, height: 560)
	}

	#Preview("First run") {
		ContentView(exchange: LibraryExchange(model: .previewingFirstRun))
	}
#endif
