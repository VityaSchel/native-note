import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LibrarySearchTests {
	private let alarm = Alarm()

	private func library(_ bodies: [String]) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		for body in bodies {
			await model.createNote()
			model.edit(try #require(model.selection), body)
		}
		await model.flushPendingSaves()
		return (model, directory)
	}

	@Test func searchFiltersTheGroupsAndClearingItRestoresThem() async throws {
		let (model, directory) = try await library(["Shopping\nquartz and bread", "Standup\nshipped storage"])
		defer { try? FileManager.default.removeItem(at: directory) }

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

	@Test func aPrefixOfTheLastWordMatchesWhileTyping() async throws {
		let (model, directory) = try await library(["kayak trip", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }

		model.search = "kay"
		await model.runSearch()

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak trip"])
	}

	@Test func aSingleLetterMatchesOnlyAWholeWord() async throws {
		let (model, directory) = try await library(["kayak trip", "k is for kayak"])
		defer { try? FileManager.default.removeItem(at: directory) }

		model.search = "k"
		await model.runSearch()

		#expect(model.groups.flatMap(\.notes).map(\.body) == ["k is for kayak"])
	}

	@Test func resultsAreOrderedByRelevanceNotDate() async throws {
		let (model, directory) = try await library(["kayak kayak kayak", "kayak rental prices and opening hours"])
		defer { try? FileManager.default.removeItem(at: directory) }

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.count == 1)
		#expect(model.groups.flatMap(\.notes).map(\.body) == ["kayak kayak kayak", "kayak rental prices and opening hours"])
	}

	@Test func clearingTheSearchWhileOneRunsShowsEveryNote() async throws {
		let (model, directory) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }

		model.search = "kayak"
		let typing = Task { await model.runSearch() }
		await Task.yield()
		model.search = ""
		await model.runSearch()
		await typing.value

		#expect(model.groups.flatMap(\.notes).count == 2)
	}

	@Test func searchingWhileLockedDoesNothing() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		await model.lock()

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure == nil)
	}

	@Test func lockingKeepsTheSearchAndRefreshesItsResults() async throws {
		let (model, directory) = try await library(["kayak", "canoe"])
		defer { try? FileManager.default.removeItem(at: directory) }
		model.search = "kayak"
		await model.runSearch()
		let canoe = try #require(model.notes.first { $0.body == "canoe" }?.id)

		model.edit(canoe, "canoe or kayak")
		await model.lock()
		await model.unlock(password: workspacePassword)

		#expect(model.search == "kayak")
		#expect(Set(model.groups.flatMap(\.notes).map(\.body)) == ["kayak", "canoe or kayak"])
	}

	@Test func aFailedSearchReportsTheErrorAndShowsNothing() async throws {
		let (model, directory) = try await library(["kayak"])
		defer { try? FileManager.default.removeItem(at: directory) }
		try await connection(to: directory).execute("DROP TABLE note_fts")

		model.search = "kayak"
		await model.runSearch()

		#expect(model.groups.isEmpty)
		#expect(model.failure?.isUnexpected == true)
	}

	@Test func aFailingSearchIsReportedOnceWhileTheUserTypes() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
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
		let (model, directory) = try await library(["kayak"])
		defer { try? FileManager.default.removeItem(at: directory) }
		try await connection(to: directory).execute("DROP TABLE note_fts")

		model.search = "kayak"
		let searching = Task { await model.runSearch() }
		await Task.yield()
		await model.lock()
		await searching.value

		#expect(model.failure == nil)
	}

	@Test func lockingClearsALibraryFailure() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await connection(to: directory).execute("DROP TABLE note_fts")
		model.search = "kayak"
		await model.runSearch()
		try #require(model.failure != nil)

		await model.lock()

		#expect(model.failure == nil)
	}
}

private extension AppModel.Failure {
	var isUnexpected: Bool {
		if case .unexpected = self { true } else { false }
	}
}
