import NativeNoteKit
import SwiftUI

@main
struct NativeNoteApp: App {
	@NSApplicationDelegateAdaptor private var delegate: AppDelegate
	@AppStorage(EditorZoom.key) private var zoom = 1.0

	var body: some Scene {
		Window("Native Note", id: LibraryExchange.window) {
			ContentView(exchange: delegate.exchange)
		}
		.defaultLaunchBehavior(AppDelegate.hostsTests ? .automatic : .presented)
		Settings {
			SettingsView(model: delegate.model)
		}
		.windowResizability(.contentSize)
		.commands {
			TextEditingCommands()
			SidebarCommands()
			ToolbarCommands()
			CommandGroup(before: .toolbar) {
				Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = EditorZoom.larger(zoom) }
					.keyboardShortcut("+")
					.disabled(zoom >= EditorZoom.range.upperBound)
				Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = EditorZoom.smaller(zoom) }
					.keyboardShortcut("-")
					.disabled(zoom <= EditorZoom.range.lowerBound)
				Button("Actual Size", systemImage: "square.resize") { zoom = 1 }
					.keyboardShortcut("0")
					.disabled(zoom == 1)
			}
			CommandGroup(after: .textEditing) {
				Button("Search Notes") { delegate.exchange.searchNotes() }
					.keyboardShortcut("f", modifiers: [.shift, .command])
					.disabled(!delegate.exchange.acceptsCommands)
			}
			CommandGroup(replacing: .newItem) {
				Button("New Note") { delegate.exchange.newNote() }
					.keyboardShortcut("n")
					.disabled(!delegate.exchange.acceptsCommands)
				Button("Sync Now") { Task { await delegate.model.syncNow() } }
					.keyboardShortcut("r")
					.disabled(!delegate.exchange.canSync)
				Divider()
				Button("Lock") { Task { await delegate.model.lock() } }
					.keyboardShortcut("l")
					.disabled(!delegate.exchange.acceptsCommands)
			}
			CommandGroup(replacing: .importExport) {
				Button("Export…") { delegate.exchange.startExport() }
					.disabled(!delegate.exchange.canExchange)
				Button("Import…") { delegate.exchange.chooseImport() }
					.disabled(!delegate.exchange.canExchange)
			}
			CommandGroup(replacing: .help) {
				Button("Native Note Help") { Guide.open(Guide.gettingStarted) }
					.keyboardShortcut("?")
			}
		}
	}
}
