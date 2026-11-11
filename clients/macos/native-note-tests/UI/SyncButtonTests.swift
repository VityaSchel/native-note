import AppKit
import Testing

@testable import NativeNote
@testable import NativeNoteKit

@MainActor
struct SyncButtonTests {
	private let server = "http://notes.example:8080/"

	@Test func idleSaysWhenItLastSynced() {
		let button = SyncButton(status: AppModel.SyncStatus(phase: .idle, server: server)) {}

		#expect(button.symbol == "arrow.triangle.2.circlepath")
		#expect(button.help == "Not synced yet")
	}

	@Test func aFailureShowsAWarningWithItsReason() {
		let button = SyncButton(status: AppModel.SyncStatus(phase: .failed("The server could not be reached."), server: server)) {}

		#expect(button.symbol == "exclamationmark.arrow.triangle.2.circlepath")
		#expect(button.help == "Sync failed: The server could not be reached.")
	}

	@Test func theToolbarHasSyncNowOnlyWhileSyncIsSetUp() async throws {
		let (model, directory) = try await unlockedModel(alarm: Alarm())
		defer { try? FileManager.default.removeItem(at: directory) }
		let offscreen = OffscreenWindow(ContentView(exchange: LibraryExchange(model: model)), width: 980, height: 560)
		defer { offscreen.close() }
		offscreen.pump()
		#expect(!(offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false))

		model.syncStatus = AppModel.SyncStatus(phase: .idle, server: server)
		await offscreen.pump { offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false }

		#expect(offscreen.window.toolbar?.items.contains { $0.label == "Sync Now" } ?? false)
	}

	@Test func syncNowWaitsForSetupAndForARunningSync() async throws {
		let (model, directory) = try await unlockedModel(alarm: Alarm())
		defer { try? FileManager.default.removeItem(at: directory) }
		let exchange = LibraryExchange(model: model)
		#expect(!exchange.canSync)

		model.syncStatus = AppModel.SyncStatus(phase: .idle, server: server)
		#expect(exchange.canSync)
		model.syncStatus.phase = .syncing
		#expect(!exchange.canSync)
	}
}
