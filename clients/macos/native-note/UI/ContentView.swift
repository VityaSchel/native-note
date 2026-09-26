import NativeNoteKit
import SwiftUI

struct ContentView: View {
	@Bindable var exchange: LibraryExchange
	@Bindable var model: AppModel

	init(exchange: LibraryExchange) {
		self.exchange = exchange
		model = exchange.model
	}

	var body: some View {
		Group {
			switch model.phase {
			case .loading:
				ProgressView().onAppear { model.start() }
			case .needsSetup, .locked:
				UnlockView(
					isSetup: model.phase == .needsSetup,
					failure: model.failure,
					submit: model.submit(password:),
					dismissFailure: model.dismissFailure,
					unlockWithBiometrics: model.canUnlockWithBiometrics ? { await model.unlockWithBiometrics() } : nil,
					eraseLibrary: { Task { await model.eraseLibrary() } }
				)
			case .unlocked:
				library
			}
		}
		.frame(minWidth: 720, minHeight: 460)
		.onDisappear { Task { await model.flushPendingSaves() } }
	}

	static func noteCount(_ count: Int) -> String {
		count == 1 ? "1 note" : "\(count) notes"
	}

	private var library: some View {
		NavigationSplitView {
			List {
				Label("All notes", systemImage: "tray.full")
			}
			.navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
		} content: {
			NoteListView(groups: model.groups, selection: $model.selection, search: $model.search)
				.navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
				.navigationTitle("All notes")
				.navigationSubtitle(Self.noteCount(model.noteCount))
				.onChange(of: model.search) { Task { await model.runSearch() } }
				.alert(exchange.lastImport?.message ?? "", isPresented: $exchange.showsSummary) {
					Button("OK") {}
				}
		} detail: {
			if let note = model.selectedNote {
				NoteEditor(text: Binding(get: { note.body }, set: { model.edit(note.id, $0) }))
					.id(note.id)
			} else {
				ContentUnavailableView("No note selected", systemImage: "note.text")
			}
		}
		.toolbar {
			ToolbarItem {
				Button { Task { await model.createNote() } } label: {
					Label("New note", systemImage: "square.and.pencil")
				}
			}
			ToolbarItem {
				Button { Task { await model.deleteSelected() } } label: {
					Label("Delete", systemImage: "trash")
				}
				.disabled(model.selection == nil)
			}
			ToolbarItem {
				Button { Task { await model.lock() } } label: {
					Label("Lock", systemImage: "lock")
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
			case .conflicts:
				ConflictSheet(conflicts: model.conflicts) { conflict, choice in
					Task { await model.resolve(conflict, choice) }
				}
				.interactiveDismissDisabled()
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
