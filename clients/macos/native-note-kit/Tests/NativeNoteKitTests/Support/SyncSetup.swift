import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
func syncingModel(_ server: SyncServer, alarm: Alarm? = nil, idle: Duration = .milliseconds(50)) async throws -> (AppModel, TestTransport) {
	let transport = TestTransport(server)
	let (model, _) = try await unlockedModel { .testing(in: $0, scheduler: alarm?.scheduler ?? SaveScheduler(), transport: transport, syncDelay: idle) }
	return (model, transport)
}

@MainActor
func apiKeyText(_ server: SyncServer) throws -> String {
	try String(contentsOf: server.data.appending(path: "api-key"), encoding: .utf8)
}

@MainActor
func answers(_ phrase: AppModel.RecoveryPhrase) -> [String] {
	phrase.positionsToConfirm.map { phrase.words[$0] }
}

func newLibrary(_ start: Result<AppModel.SyncSetupStart, AppModel.SyncSetupFailure>) throws -> AppModel.RecoveryPhrase {
	guard case let .newLibrary(phrase) = try start.get() else { throw AppModel.SyncSetupFailure.serverHasLibrary }
	return phrase
}

@MainActor
func setUpSync(_ model: AppModel, _ server: SyncServer) async throws -> AppModel.RecoveryPhrase {
	let phrase = try newLibrary(await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)))
	try #require(await model.finishSync(answers: answers(phrase)) == nil)
	return phrase
}

@MainActor
func storedBlob(_ server: SyncServer) async throws -> (v: UInt32, blob: Data) {
	let connection = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
	guard case let .get(v, blob) = try await connection.send(.get) else { throw SyncError.protocolViolation }
	return (v, blob)
}

@MainActor
func libraryWithUnreadableServerAddress() async throws -> AppModel {
	let (model, directory) = try await unlockedModel { .testing(in: $0) }
	let settings = SyncSettings(server: try #require(URL(string: "http://127.0.0.1:9/")), apiKey: SymmetricKey(size: .bits256), contentKey: SymmetricKey(size: .bits256))
	try await #require(model.store).enableSync(settings, pin: 1)
	await model.lock()
	try await connection(to: directory).execute("UPDATE meta SET v = CAST('nowhere' AS BLOB) WHERE k = 'server'")
	await model.unlock(password: workspacePassword)
	return model
}
