import NativeNoteKit
import SwiftUI

@main
struct NativeNoteApp: App {
	@NSApplicationDelegateAdaptor private var delegate: AppDelegate
	@AppStorage(EditorZoom.key) private var magnification = 1.0

	var body: some Scene {
		Window("Native Note", id: "library") {
			ContentView(exchange: delegate.exchange)
		}
		Settings {
			SettingsView(model: delegate.model)
		}
		.windowResizability(.contentSize)
		.commands {
			TextEditingCommands()
			SidebarCommands()
			ToolbarCommands()
			CommandGroup(before: .toolbar) {
				Button("Actual Size") { magnification = 1 }
					.keyboardShortcut("0")
					.disabled(magnification == 1)
				Button("Zoom In") { magnification = EditorZoom.larger(magnification) }
					.keyboardShortcut("+")
					.disabled(magnification >= EditorZoom.range.upperBound)
				Button("Zoom Out") { magnification = EditorZoom.smaller(magnification) }
					.keyboardShortcut("-")
					.disabled(magnification <= EditorZoom.range.lowerBound)
				Divider()
			}
			CommandGroup(after: .textEditing) {
				Button("Search Notes") { delegate.exchange.focusSearch() }
					.keyboardShortcut("f", modifiers: [.shift, .command])
					.disabled(!delegate.exchange.acceptsCommands)
			}
			CommandGroup(replacing: .newItem) {
				Button("New Note") { Task { await delegate.model.createNote() } }
					.keyboardShortcut("n")
					.disabled(!delegate.exchange.acceptsCommands)
				Button("Sync Now") { Task { await delegate.model.syncNow() } }
					.keyboardShortcut("r")
					.disabled(!delegate.exchange.canSync)
				Divider()
				Button("Lock") { Task { await delegate.model.lock() } }
					.keyboardShortcut("l", modifiers: [.control, .command])
					.disabled(!delegate.exchange.acceptsCommands)
			}
			CommandGroup(replacing: .importExport) {
				Button("Export…") { delegate.exchange.isExporting = true }
					.disabled(!delegate.exchange.canExchange)
				Button("Import…") { delegate.exchange.chooseImport() }
					.disabled(!delegate.exchange.canExchange)
			}
		}
	}
}
