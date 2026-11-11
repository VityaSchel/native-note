import NativeNoteKit
import SwiftUI

struct ContentView: View {
	@Bindable var exchange: LibraryExchange
	@Bindable var model: AppModel
	let clipboard: RecoveryClipboard
	@Environment(\.undoManager) private var undoManager
	@AppStorage(EditorZoom.key) private var magnification = 1.0

	init(exchange: LibraryExchange, clipboard: RecoveryClipboard = .shared) {
		self.exchange = exchange
		model = exchange.model
		self.clipboard = clipboard
	}

	private func delete(_ id: UUID) {
		if let kept = model.keepForUndo(id) { offerUndo(of: kept) }
		Task { await model.delete(id) }
	}

	/// Undo restores the text as a new note, and redo deletes that note again.
	private func offerUndo(of kept: UUID) {
		guard let undoManager else { return }
		undoManager.registerUndo(withTarget: model) { [weak undoManager] model in
			MainActor.assumeIsolated {
				guard let restored = model.restore(kept) else { return }
				undoManager?.registerUndo(withTarget: model) { _ in
					MainActor.assumeIsolated { delete(restored) }
				}
				undoManager?.setActionName("Delete Note")
			}
		}
		undoManager.setActionName("Delete Note")
	}

	var body: some View {
		screen
			.frame(minWidth: 720, minHeight: 460)
			.onDisappear { Task { await model.flushPendingSaves() } }
			.onChange(of: model.phase) { _, phase in
				guard phase != .unlocked else { return }
				undoManager?.removeAllActions()
				clipboard.clear()
			}
	}

	@ViewBuilder
	private var screen: some View {
		switch model.phase {
			case .loading:
				ProgressView().onAppear { model.start() }
			case .needsSetup, .locked:
				UnlockView(
					isSetup: model.phase == .needsSetup,
					failure: model.failure,
					submit: { password in
						await model.submit(password: password)
						return model.failure
					},
					dismissFailure: model.dismissFailure,
					touchID: TouchIDControls(model),
					shake: model.shake,
					eraseLibrary: { Task { await model.eraseLibrary() } },
					hasSecureEnclave: AppModel.hasSecureEnclave
				)
			case .unlocked:
				if model.offersSyncSetup {
					syncOnboarding
				} else {
					library
				}
		}
	}

	static func noteCount(_ count: Int) -> String {
		count == 1 ? "1 note" : "\(count) notes"
	}

	private var syncOnboarding: some View {
		SyncSetupView(
			form: SyncSetupForm(mode: .setUp),
			controls: SyncControls(model),
			clipboard: clipboard,
			declineTitle: "Not Now",
			isPage: true,
			done: model.dismissSyncSetupOffer
		)
	}

	private static let allNotes = "all"

	/// An empty library says so once, in the list, as Notes does.
	@ViewBuilder
	private var detail: some View {
		if let note = model.selectedNote {
			NoteEditor(
				text: Binding(get: { note.body }, set: { model.edit(note.id, $0) }),
				takesFocus: model.focusesEditor == note.id,
				tookFocus: model.editorTookFocus,
				magnification: magnification,
				dateLine: NoteGrouping.editorDateLine(for: note.updated)
			)
			.id(note.id)
		} else if model.noteCount > 0 {
			ContentUnavailableView("No Note Selected", systemImage: "note.text")
		} else {
			Color.clear
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
				NoteListView(groups: model.groups, now: timeline.date, selection: $model.selection, search: $model.search) { id in
					delete(id)
				}
			}
			.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
			.toolbar {
				ToolbarItem {
					Button { model.selection.map(delete) } label: {
						Label("Delete", systemImage: "trash")
					}
					.disabled(model.selection == nil)
				}
			}
			.navigationTitle("All Notes")
			.navigationSubtitle(Self.noteCount(model.noteCount))
			.onChange(of: model.search) { Task { await model.runSearch() } }
			.alert(exchange.lastImport?.message ?? "", isPresented: $exchange.showsSummary) {
				Button("OK") {}
			}
		} detail: {
			detail
				.toolbar {
					ToolbarItem {
						Button { Task { await model.createNote() } } label: {
							Label("New Note", systemImage: "square.and.pencil")
						}
					}
					ToolbarSpacer(.flexible)
					ToolbarItemGroup {
						if model.syncStatus.server != nil {
							SyncButton(status: model.syncStatus) { Task { await model.syncNow() } }
						}
						Button { Task { await model.lock() } } label: {
							Label("Lock", systemImage: "lock")
						}
					}
				}
		}
		.failureAlert(model.failure, dismiss: model.dismissFailure)
		.sheet(item: $exchange.presentedSheet) { sheet in
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
