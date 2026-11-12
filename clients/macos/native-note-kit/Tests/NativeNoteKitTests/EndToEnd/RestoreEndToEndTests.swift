import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.serialized, .timeLimit(.minutes(10)))
struct RestoreEndToEndTests {
	private struct Snapshot: Equatable {
		let body: String
		let created: Int64
		let updated: Int64
	}

	private let corpus = RealisticCorpus.bodies(count: 300)

	private func snapshot(_ notes: [Note]) -> [UUID: Snapshot] {
		Dictionary(uniqueKeysWithValues: notes.map { ($0.id, Snapshot(body: $0.body, created: $0.createdAt, updated: $0.updatedAt)) })
	}

	private func firstRun(password: String) async throws -> (AppModel, URL) {
		let directory = temporaryDirectory()
		let model = AppModel(directory: directory)
		model.start()
		try #require(model.phase == .needsSetup)
		await model.submit(password: password)
		try #require(model.phase == .unlocked)
		return (model, directory)
	}

	private func relaunch(_ directory: URL, password: String) async throws -> AppModel {
		let model = AppModel(directory: directory)
		model.start()
		await model.submit(password: password)
		try #require(model.phase == .unlocked)
		return model
	}

	private func restore(_ server: SyncServer, phrase: [String], apiKey: String, password: String) async throws -> (AppModel, URL) {
		let (model, directory) = try await firstRun(password: password)
		var typed = PhraseEntry()
		_ = typed.set(phrase.joined(separator: " "), at: 0)
		#expect(await model.prepareSync(server: server.url.absoluteString, apiKey: apiKey) == .success(.existingLibrary))
		try #require(await model.joinSync(server: server.url.absoluteString, apiKey: apiKey, phrase: typed) == nil)
		await model.syncNow()
		try #require(model.syncStatus.phase == .idle, "\(model.syncStatus.phase)")
		return (model, directory)
	}

	@Test func aWipedMacRestoresEveryNoteFromThePhraseAndEditsFlowBothWays() async throws {
		let server = try SyncServer()
		let keyFile = try String(contentsOf: server.data.appending(path: "api-key"), encoding: .utf8)
		let keptKey = keyFile.trimmingCharacters(in: .whitespacesAndNewlines)
		let (original, originalDirectory) = try await firstRun(password: "first Mac")
		try await fill(original, with: corpus)
		await original.delete(try #require(original.notes.first).id)
		guard case let .newLibrary(phrase) = try await original.prepareSync(server: server.url.absoluteString, apiKey: keptKey).get() else {
			Issue.record("a fresh server offered a join")
			return
		}
		try #require(await original.finishSync(answers: phrase.positionsToConfirm.map { phrase.words[$0] }) == nil)
		await original.syncNow()
		let saved = snapshot(original.notes)
		await original.close()
		try FileManager.default.removeItem(at: originalDirectory)

		let (kept, keptDirectory) = try await restore(server, phrase: phrase.words, apiKey: keptKey, password: "restored with the kept key")
		defer { try? FileManager.default.removeItem(at: keptDirectory) }
		#expect(snapshot(kept.notes) == saved)
		#expect(try await kept.store?.liveNotes().allSatisfy { !$0.dirty } == true)

		let (reread, rereadDirectory) = try await restore(server, phrase: phrase.words, apiKey: keyFile, password: "restored with the key file")
		defer { try? FileManager.default.removeItem(at: rereadDirectory) }
		#expect(snapshot(reread.notes) == saved)

		let edited = try #require(kept.notes.first { $0.body.count > 40 })
		kept.edit(edited.id, edited.body + "\nAdded after the restore.")
		await reread.createNote()
		let created = try #require(reread.selection)
		reread.edit(created, "Written on the second restore")
		let removed = try #require(reread.notes.first { $0.id != edited.id && $0.id != created })
		await reread.delete(removed.id)
		await kept.syncNow()
		await reread.syncNow()
		await kept.syncNow()

		#expect(snapshot(kept.notes) == snapshot(reread.notes))
		#expect(kept.notes.contains { $0.body == edited.body + "\nAdded after the restore." })
		#expect(kept.notes.contains { $0.body == "Written on the second restore" })
		#expect(!kept.notes.contains { $0.id == removed.id })
		#expect(kept.notes.count == saved.count)

		let after = snapshot(kept.notes)
		await kept.close()
		await reread.close()
		let relaunched = try await relaunch(keptDirectory, password: "restored with the kept key")
		#expect(snapshot(relaunched.notes) == after)
		#expect(relaunched.syncStatus.server == server.url.absoluteString)
		await relaunched.syncNow()
		#expect(relaunched.syncStatus.phase == .idle)
		#expect(snapshot(relaunched.notes) == after)
	}
}
