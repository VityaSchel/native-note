import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

final class RecordingTransport: SyncTransport, @unchecked Sendable {
	private let http: HTTPTransport
	private let lock = NSLock()
	private(set) var exchanges: [(request: Data, reply: Data)] = []

	init(_ server: SyncServer) {
		http = HTTPTransport(url: server.url)
	}

	func post(_ body: Data) async throws -> Data {
		let reply = try await http.post(body)
		lock.withLock { exchanges.append((body, reply)) }
		return reply
	}
}

@MainActor @Suite(.scratch, .syncServer, .timeLimit(.minutes(2)))
struct ServerViewTests {
	private struct Library {
		let model: AppModel
		let recorder: RecordingTransport
		let phrase: AppModel.RecoveryPhrase
		let ids: [UUID]
		let settings: SyncSettings
	}

	private static let buckets = Set((0 ... 13).map { 256 << $0 })
	private let bodies = RealisticCorpus.bodies(count: 40, seed: 0x7E57)

	private func library(_ server: SyncServer) async throws -> Library {
		let recorder = RecordingTransport(server)
		let (model, _) = try await unlockedModel { directory in
			AppModel.testing(in: directory, transport: recorder)
		}
		try await fill(model, with: bodies)
		let ids = model.notes.map(\.id)
		await model.delete(try #require(ids.first))
		let phrase = try newLibrary(await model.prepareSync(server: server.url.absoluteString, apiKey: apiKeyText(server)))
		try #require(await model.finishSync(answers: answers(phrase)) == nil)
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle)
		let settings = try #require(try await model.store?.syncSettings())
		return Library(model: model, recorder: recorder, phrase: phrase, ids: ids, settings: settings)
	}

	private var secrets: [Data] {
		bodies.flatMap { $0.split(whereSeparator: \.isWhitespace).filter { $0.utf8.count >= 8 }.prefix(2) }.map { Data($0.utf8) }
	}

	private func identities(_ ids: [UUID]) -> [Data] {
		ids.flatMap { [$0.bytes, Data($0.uuidString.utf8), Data($0.uuidString.lowercased().utf8)] }
	}

	private func openRequest(_ body: Data, apiKey: SymmetricKey) -> Request? {
		let key = KeyDerivation.derive(ikm: apiKey, info: KeyDerivation.envelope)
		guard let box = try? AES.GCM.SealedBox(combined: body), let padded = try? AES.GCM.open(box, using: key),
			let inner = Padding.unpad(padded)
		else { return nil }
		return try? RequestDecoding.decode(inner)
	}

	@Test func theServerStoresNoNoteTextIdentityOrKey() async throws {
		let server = try SyncServer()
		let library = try await library(server)
		let recoveryKey = try #require(Mnemonic.key(from: library.phrase.words))
		server.kill()

		let stored = try FileManager.default.contentsOfDirectory(at: server.data, includingPropertiesForKeys: nil)
			.filter { $0.lastPathComponent != "api-key" }
			.reduce(into: Data()) { $0.append(try Data(contentsOf: $1)) }

		#expect(secrets.count >= bodies.count)
		#expect(stored.count > library.ids.count * Content.block)
		for secret in secrets + identities(library.ids) {
			#expect(stored.range(of: secret) == nil, "\(String(decoding: secret, as: UTF8.self))")
		}
		for key in [library.settings.contentKey, recoveryKey] {
			#expect(key.withUnsafeBytes { stored.range(of: Data($0)) } == nil)
		}
	}

	@Test func everyEnvelopeOnTheWireIsBucketSizedAndHoldsNothingInTheClear() async throws {
		let server = try SyncServer()
		let library = try await library(server)
		let cipher = NoteCipher(contentKey: library.settings.contentKey)
		let clear = secrets + identities(library.ids) + library.ids.map(cipher.blindedId(for:))

		#expect(library.recorder.exchanges.count >= 3)
		for (request, reply) in library.recorder.exchanges {
			for body in [request, reply] {
				#expect(Self.buckets.contains(body.count - EnvelopeKey.nonceLength - 16), "\(body.count)")
				for value in clear {
					#expect(body.range(of: value) == nil)
				}
			}
		}
	}

	@Test func aLeakedAPIKeyOpensCapturedEnvelopesToMetadataButNotToNotes() async throws {
		let server = try SyncServer()
		let library = try await library(server)
		let apiKey = try server.apiKey
		let requests = library.recorder.exchanges.compactMap { openRequest($0.request, apiKey: apiKey) }
		let writes: [Write] = requests.flatMap { request -> [Write] in
			guard case let .sync(_, writes) = request else { return [] }
			return writes
		}

		let cipher = NoteCipher(contentKey: library.settings.contentKey)
		#expect(Set(writes.map(\.blindedId)) == Set(library.ids.map(cipher.blindedId(for:))))
		#expect(writes.allSatisfy { $0.v == 1 })
		let guess = NoteCipher(contentKey: SymmetricKey(size: .bits256))
		for write in writes {
			#expect(guess.open(write) == nil)
			#expect(cipher.open(write) != nil)
			for secret in secrets {
				#expect(write.payload.range(of: secret) == nil)
			}
		}
	}

	@Test func theServerSeesEachNotesVersionCountAndNothingElseOfIt() async throws {
		let server = try SyncServer()
		let library = try await library(server)
		let edited = try #require(library.model.notes.first)
		for round in 1 ... 4 {
			library.model.edit(edited.id, "edited \(round) times")
			await library.model.flushPendingSaves()
			await library.model.syncNow()
		}

		let serverOperator = SyncConnection(apiKey: try server.apiKey, transport: HTTPTransport(url: server.url))
		guard case let .sync(_, changes, _, _) = try await serverOperator.send(.sync(since: 0, writes: [])) else {
			Issue.record("the pull did not answer as a sync")
			return
		}

		let seen = try #require(changes.first { $0.blindedId == NoteCipher(contentKey: library.settings.contentKey).blindedId(for: edited.id) })
		#expect(seen.v == 5)
		#expect(seen.payload.range(of: Data("edited 4 times".utf8)) == nil)
		#expect(changes.allSatisfy { $0.payload.count % Content.block == 28 })
	}
}
