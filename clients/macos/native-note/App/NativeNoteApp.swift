import SwiftUI

@main
struct NativeNoteApp: App {
	@NSApplicationDelegateAdaptor private var delegate: AppDelegate

	var body: some Scene {
		WindowGroup {
			ContentView(model: delegate.model)
		}
	}
}
