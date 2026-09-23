import SwiftUI

struct ContentView: View {
	@Bindable var model: AppModel

	var body: some View {
		Group {
			switch model.phase {
			case .loading:
				ProgressView().onAppear { model.start() }
			case .needsSetup:
				UnlockView(
					isSetup: true,
					failure: model.failure,
					submit: { await model.setUp(password: $0) },
					dismissFailure: model.dismissFailure
				)
			case .locked:
				UnlockView(
					isSetup: false,
					failure: model.failure,
					submit: { await model.unlock(password: $0) },
					dismissFailure: model.dismissFailure
				)
			case .unlocked:
				library
			}
		}
		.frame(minWidth: 720, minHeight: 460)
		.onDisappear { Task { await model.flushPendingSaves() } }
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
				.onChange(of: model.search) { Task { await model.runSearch() } }
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
	}
}

#if DEBUG
	#Preview("Library") {
		ContentView(model: .previewing(NoteGroup.samples.flatMap(\.notes)))
			.frame(width: 980, height: 560)
	}

	#Preview("Library, edits not saved") {
		ContentView(model: .previewing(NoteGroup.samples.flatMap(\.notes), failure: .unsaved("disk I/O error")))
			.frame(width: 980, height: 560)
	}

	#Preview("First run") {
		ContentView(model: AppModel(directory: URL(fileURLWithPath: "/dev/null")))
	}
#endif
