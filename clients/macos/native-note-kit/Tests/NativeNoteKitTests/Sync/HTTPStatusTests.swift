import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch)
struct HTTPStatusTests {
	private struct Answering: SyncTransport {
		let status: Int

		func post(_ body: Data) async throws -> Data {
			throw SyncError.refused(status: status)
		}
	}

	private func model(answering status: Int) async throws -> AppModel {
		try await unlockedModel { AppModel(directory: $0, makeTransport: { _ in Answering(status: status) }, syncDelay: .seconds(3600)) }.0
	}

	@Test(arguments: [
		(400, "did not accept this API key, or a proxy"), (413, "at least 2 MiB + 28 B"), (502, "HTTP 502"), (302, "redirect (HTTP 302)"), (405, "Invalid response from the server: HTTP 405."),
	])
	func setupSaysWhatTheStatusMeans(status: Int, words: String) async throws {
		let model = try await model(answering: status)

		guard case let .failure(failure) = await model.prepareSync(server: "http://notes.example", apiKey: String(repeating: "a", count: 64)) else {
			Issue.record("setup went ahead")
			return
		}

		#expect(failure.message.contains(words), "\(failure.message)")
		#expect((failure == .refused) == (status == 400))
	}

	@Test(arguments: [(400, "API key, or a proxy"), (413, "at least 2 MiB + 28 B"), (503, "HTTP 503")])
	func aFailedSyncSaysWhatTheStatusMeans(status: Int, words: String) async throws {
		let model = try await model(answering: status)
		let store = try #require(model.store)
		try await store.enableSync(SyncSettings(server: URL(string: "http://notes.example")!, apiKey: .init(size: .bits256), contentKey: .init(size: .bits256)), pin: 1)
		await model.sync.start(store)
		await model.syncNow()

		guard case let .failed(message) = model.syncStatus.phase else {
			Issue.record("the sync did not fail: \(model.syncStatus.phase)")
			return
		}
		#expect(message.contains(words), "\(message)")
	}
}
