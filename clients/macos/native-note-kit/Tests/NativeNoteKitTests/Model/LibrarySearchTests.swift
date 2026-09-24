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
}
