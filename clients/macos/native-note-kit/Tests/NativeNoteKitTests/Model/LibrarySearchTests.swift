import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .timeLimit(.minutes(1)))
struct LibrarySearchTests {
	private let alarm = Alarm()
	private let held = Alarm()

	private var library: Workspace {
		Workspace(alarm: alarm)
	}

	private var libraryHoldingSearches: Workspace {
		Workspace { [alarm, held] directory, keys in
			AppModel.testing(
				in: directory,
				scheduler: alarm.scheduler,
				searchNotes: { store, text in
					try await held.sleep(for: .zero)
					return try await store.search(text)
				},
				keyStore: keys
			)
		}
	}

	@Test func searchFiltersTheGroupsAndClearingItRestoresThem() async throws {
		let (model, _) = try await library.unlocked(holding: ["Shopping\nquartz and bread", "Standup\nshipped storage"])

		model.search = "quartz"
		await model.runSearch()
		#expect(model.groups.flatMap(\.notes).map(\.title) == ["Shopping"])

		model.search = "don't"
		await model.runSearch()
		#expect(model.groups.isEmpty)

		model.search = ""
		await model.runSearch()
		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func clearingASearchWithoutMatchesShowsEveryNoteAtOnce() async throws {
		let (model, _) = try await library.unlocked(holding: ["Shopping\nquartz and bread", "Standup\nshipped storage"])
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.isEmpty)

		model.search = ""

		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func aPrefixOfTheLastWordMatchesWhileTyping() async throws {
		let (model, _) = try await library.unlocked(holding: ["kayak trip", "canoe"])

		model.search = "kay"
		await model.runSearch()

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak trip"])
	}

	@Test func aSingleLetterMatchesOnlyAWholeWord() async throws {
		let (model, _) = try await library.unlocked(holding: ["kayak trip", "k is for kayak"])

		model.search = "k"
		await model.runSearch()

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["k is for kayak"])
	}

	@Test func resultsAreOrderedByRelevanceNotDate() async throws {
		let (model, _) = try await library.unlocked(holding: ["kayak kayak kayak", "kayak rental prices and opening hours"])

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.count == 1)
		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak kayak kayak", "kayak rental prices and opening hours"])
	}

	@Test func clearingTheSearchWhileOneRunsShowsEveryNote() async throws {
		let (model, _) = try await libraryHoldingSearches.unlocked(holding: ["kayak", "canoe"])

		model.search = "kayak"
		let typing = Task { await model.runSearch() }
		try await settle { await held.sleeping == 1 }
		model.search = ""
		await model.runSearch()
		await held.ring()
		await typing.value

		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func clearingTheSearchWhileAFailingOneRunsReportsNothing() async throws {
		let (model, directory) = try await libraryHoldingSearches.unlocked(holding: ["kayak", "canoe"])
		try await connection(to: directory).execute("DROP TABLE note_fts")

		model.search = "kayak"
		let typing = Task { await model.runSearch() }
		try await settle { await held.sleeping == 1 }
		model.search = ""
		await model.runSearch()
		await held.ring()
		await typing.value

		#expect(model.failure == nil)
		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func searchingWhileLockedDoesNothing() async throws {
		let (model, _) = try await unlockedModel(alarm: alarm)
		await model.lock()

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure == nil)
	}

	@Test func lockingKeepsTheSearchAndRefreshesItsResults() async throws {
		let (model, _) = try await library.unlocked(holding: ["kayak", "canoe"])
		model.search = "kayak"
		await model.runSearch()
		let canoe = try #require(model.notes.first { $0.body == "canoe" }?.id)

		model.edit(canoe, "canoe or kayak")
		await model.lock()
		await model.unlock(password: workspacePassword)

		#expect(model.search == "kayak")
		#expect(Set(model.groups.flatMap(\.notes).map(\.body)) == ["kayak", "canoe or kayak"])
	}

	@Test func anImportedNoteShowsUpInTheSearchItMatchesAndOneThatDoesNotStaysOut() async throws {
		let (source, sourceDirectory) = try await library.unlocked(holding: ["Kayak club\nmeets on Sunday", "Canoe rental\nopen daily"])
		let file = sourceDirectory.appending(path: "export.nnexport")
		try #require(await source.exportLibrary(to: file, passphrase: nil))
		let (model, _) = try await library.unlocked(holding: ["kayak trip"])
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.flatMap(\.notes).map(\.title) == ["kayak trip"])

		try #require(await model.importLibrary(from: file, passphrase: nil) == ImportSummary(added: 2))

		#expect(Set(model.groups.flatMap(\.notes).map(\.title)) == ["kayak trip", "Kayak club"])
		#expect(model.notes.contains { $0.title == "Canoe rental" })
	}

	@Test func aPulledNoteShowsUpInTheSearchItMatchesAndOneThatDoesNotStaysOut() async throws {
		let server = ScriptedServer()
		let cipher = NoteCipher(contentKey: sharedContentKey)
		let pulled = try ["Kayak club\nmeets on Sunday", "Canoe rental\nopen daily"].map { body in
			try cipher.seal(.note(id: UUID(), createdAt: 1, updatedAt: 2, body: body), v: 1)
		}
		server.answerEvery { request in
			guard case let .sync(since, writes) = request else { return .error(.malformed) }
			let changes = since == 0 ? pulled : []
			return .sync(results: writes.map { WriteResult(status: .accepted, v: $0.v) }, changes: changes, nextSeq: since + UInt64(writes.count + changes.count), more: false)
		}
		let (model, _) = try await Workspace(holding: ["kayak trip"]) { [alarm] directory, keys in
			AppModel.testing(in: directory, scheduler: alarm.scheduler, keyStore: keys, transport: server)
		}.unlocked()
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.flatMap(\.notes).map(\.title) == ["kayak trip"])

		let store = try #require(model.store)
		try await store.enableSync(SyncSettings(server: try #require(URL(string: "http://scripted.test/")), apiKey: server.apiKey, contentKey: sharedContentKey), pin: 1)
		await model.sync.start(store)
		await model.syncNow()

		#expect(Set(model.groups.flatMap(\.notes).map(\.title)) == ["kayak trip", "Kayak club"])
		#expect(model.notes.contains { $0.title == "Canoe rental" })
	}

	@Test func anEditAPullMovesToACopyShowsUpInTheSearchItMatches() async throws {
		let (model, _) = try await library.unlocked(holding: [])
		let store = try #require(model.store)
		let id = UUID()
		func pull(_ body: String, v: UInt32) -> Commit {
			let content = Content.note(id: id, createdAt: 1, updatedAt: 2, body: body)
			return .exchange(Exchange(changes: [PulledChange(content: content, v: v, writeId: NoteCipher.randomWriteId())], nextSeq: UInt64(v)))
		}
		_ = try await model.commit(pull("kayak trip", v: 1), to: store)
		model.search = "kayak"
		await model.runSearch()
		try #require(model.groups.flatMap(\.notes).map(\.body) == ["kayak trip"])

		let applied = try await store.commit(pull("canoe rental", v: 2))
		model.edit(id, "kayak trip and a picnic")
		await model.reconcile(applied, in: store)

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak trip and a picnic"])
	}

	@Test func aFailedSearchReportsTheErrorAndShowsNothing() async throws {
		let (model, directory) = try await library.unlocked(holding: ["kayak"])
		try await connection(to: directory).execute("DROP TABLE note_fts")

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure?.searchFailed == true)
	}

	@Test func aFailingSearchIsReportedOnceWhileTheUserTypes() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await connection(to: directory).execute("DROP TABLE note_fts")

		var reports = 0
		for query in ["k", "ka", "kay", "kaya", "kayak"] {
			model.search = query
			await model.runSearch()
			if model.failure != nil { reports += 1 }
			model.dismissFailure()
		}
		model.search = ""
		await model.runSearch()
		model.search = "k"
		await model.runSearch()

		#expect(reports == 1)
		#expect(model.failure != nil)
	}

	@Test func aSearchThatFailsAfterLockIsNotReported() async throws {
		let (model, directory) = try await libraryHoldingSearches.unlocked(holding: ["kayak"])
		try await connection(to: directory).execute("DROP TABLE note_fts")

		model.search = "kayak"
		let searching = Task { await model.runSearch() }
		try await settle { await held.sleeping == 1 }
		await model.lock()
		await held.ring()
		await searching.value

		#expect(model.failure == nil)
	}

	@Test func lockingClearsALibraryFailure() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		try await connection(to: directory).execute("DROP TABLE note_fts")
		model.search = "kayak"
		await model.runSearch()
		try #require(model.failure != nil)

		await model.lock()

		#expect(model.failure == nil)
	}
}

private extension AppModel.Failure {
	var searchFailed: Bool {
		if case .failed(_, "Search could not run.") = self { true } else { false }
	}
}
