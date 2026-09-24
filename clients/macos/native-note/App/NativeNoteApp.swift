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
			CommandGroup(replacing: .importExport) {
				Button("Export…") { delegate.exchange.isExporting = true }
					.disabled(delegate.model.phase != .unlocked || !delegate.exchange.isIdle)
				Button("Import…") { delegate.exchange.chooseImport() }
					.disabled(delegate.model.phase != .unlocked || !delegate.exchange.isIdle)
			}
		}
	}
}
