import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .serialized, .enabled(if: ProcessInfo.processInfo.environment["NATIVE_NOTE_CROSS_CLIENT"] != nil), .timeLimit(.minutes(2)))
struct CrossClientTests {
	private let environment = ProcessInfo.processInfo.environment

	static func state(_ model: AppModel) -> String {
		let digests = model.notes.map { hex(SHA256.hash(data: Data($0.body.utf8))) }.sorted()
		return hex(SHA256.hash(data: Data(digests.joined(separator: "\n").utf8)))
	}

	private static func hex(_ digest: SHA256.Digest) -> String {
		digest.map { String(format: "%02x", $0) }.joined()
	}

	private func value(_ name: String) throws -> String {
		try #require(environment[name], "\(name) is not set")
	}

	@Test func writesALibraryForAnotherClient() async throws {
		try #require(environment["NATIVE_NOTE_CROSS_CLIENT"] == "write")
		let (server, apiKey) = (try value("NATIVE_NOTE_SERVER"), try value("NATIVE_NOTE_API_KEY"))
		let (model, _) = try await Workspace(holding: RealisticCorpus.bodies(count: 40)) { .testing(in: $0, keyStore: $1) }.unlocked()

		let phrase = try newLibrary(await model.prepareSync(server: server, apiKey: apiKey))
		try #require(await model.finishSync(answers: answers(phrase)) == nil)
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(model.syncStatus.problems.isEmpty)
		try "\(phrase.words.joined(separator: " "))\n\(Self.state(model))\n".write(to: URL(filePath: try value("NATIVE_NOTE_OUT")), atomically: true, encoding: .utf8)
		await model.lock()
	}

	@Test func readsWhatAnotherClientWrote() async throws {
		try #require(environment["NATIVE_NOTE_CROSS_CLIENT"] == "read")
		let (server, apiKey) = (try value("NATIVE_NOTE_SERVER"), try value("NATIVE_NOTE_API_KEY"))
		let (model, _) = try await Workspace { .testing(in: $0, keyStore: $1) }.unlocked()
		var entry = PhraseEntry()
		_ = entry.set(try value("NATIVE_NOTE_WORDS"), at: 0)

		#expect(await model.prepareSync(server: server, apiKey: apiKey) == .success(.existingLibrary))
		#expect(await model.joinSync(server: server, apiKey: apiKey, phrase: entry) == nil)
		await model.syncNow()

		#expect(model.syncStatus.phase == .idle)
		#expect(Self.state(model) == (try value("NATIVE_NOTE_EXPECT")))
		await model.lock()
	}
}
