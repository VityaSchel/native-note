import NativeNoteKit
import SwiftUI

@main
struct NativeNoteApp: App {
	@NSApplicationDelegateAdaptor private var delegate: AppDelegate

	var body: some Scene {
		Window("Native Note", id: "library") {
			ContentView(exchange: delegate.exchange)
		}
		.commands {
			CommandGroup(replacing: .newItem) {
				Button("New Note") { Task { await delegate.model.createNote() } }
					.keyboardShortcut("n")
					.disabled(!delegate.exchange.acceptsCommands)
			}
			CommandGroup(replacing: .importExport) {
				Button("Export…") { delegate.exchange.isExporting = true }
					.disabled(!delegate.exchange.acceptsCommands)
				Button("Import…") { delegate.exchange.chooseImport() }
					.disabled(!delegate.exchange.acceptsCommands)
			}
		}
	}
}
