import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

private struct RewrittenRequests: SyncTransport {
	let server: SyncServer
	let rewrite: @Sendable (Data) -> Data

	func post(_ body: Data) async throws -> Data {
		let key = KeyDerivation.derive(ikm: try server.apiKey, info: KeyDerivation.envelope)
		let inner = try #require(Padding.unpad(try AES.GCM.open(AES.GCM.SealedBox(combined: body), using: key)))
		let nonce = try AES.GCM.Nonce(data: body.prefix(EnvelopeKey.nonceLength))
		return try await HTTPTransport(url: server.url).post(try EnvelopeKey(derived: key).seal(rewrite(inner), nonce: nonce))
	}
}

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(1)))
struct ServerErrorReasonTests {
	@Test(arguments: [
		("an action the server does not know", "This server needs a newer version of Native Note."),
		("a request with a byte past its end", "The server could not read Native Note's request."),
	])
	func theRealServersErrorReasonIsWhatSyncAndSetupReport(request: String, message: String) async throws {
		let server = try SyncServer()
		let transport = RewrittenRequests(server: server) { inner in
			request == "an action the server does not know" ? Data([0x7f]) + inner.dropFirst() : inner + Data([0])
		}
		let (syncing, _) = try await unlockedModel { AppModel.testing(in: $0, transport: transport) }
		try await fill(syncing, with: ["stays here"])
		let store = try #require(syncing.store)
		try await store.enableSync(SyncSettings(server: server.url, apiKey: try server.apiKey, contentKey: sharedContentKey), pin: 1)
		await syncing.sync.start(store)

		await syncing.syncNow()

		#expect(syncing.syncStatus.phase == .failed(message))
		#expect(try await store.pendingPushes().map(\.body) == ["stays here"])
		#expect(try await store.since() == 0)
		let (settingUp, _) = try await unlockedModel { AppModel.testing(in: $0, transport: transport) }
		#expect(await settingUp.prepareSync(server: server.url.absoluteString, apiKey: try apiKeyText(server)) == .failure(.failed(message)))
		#expect(try await settingUp.store?.syncSettings() == nil)
		#expect(try await storedBlob(server).v == 0)
	}
}
