import Foundation

@testable import NativeNoteKit

extension AppModel {
	@MainActor
	static func testing(
		in directory: URL,
		scheduler: SaveScheduler = SaveScheduler(),
		makeParameters: @escaping @Sendable () throws -> UnlockParameters = { .fast },
		calibrate: @escaping @Sendable () throws -> Argon2.Parameters = { UnlockParameters.fast.argon },
		searchNotes: @escaping @Sendable (NoteStore, String) async throws -> [Note] = AppModel.search,
		exportParameters: Argon2.Parameters = Argon2.floor,
		keyStore: any UnlockKeyStore = FakeKeyStore(),
		records: (any UnlockRecordStore)? = nil,
		shakeTimer: @escaping SaveScheduler.Sleep = { try await Task.sleep(for: $0) },
		transport: (any SyncTransport)? = nil,
		makeTransport: (@Sendable (URL) -> any SyncTransport)? = nil,
		syncDelay: Duration = .seconds(3600)
	) -> AppModel {
		AppModel(
			directory: directory,
			scheduler: scheduler,
			makeParameters: makeParameters,
			calibrate: calibrate,
			searchNotes: searchNotes,
			exportParameters: exportParameters,
			keyStore: keyStore,
			records: records ?? FileUnlockRecordStore(directory: directory),
			shakeTimer: shakeTimer,
			makeTransport: makeTransport ?? { transport ?? HTTPTransport(url: $0) },
			syncDelay: syncDelay
		)
	}
}
