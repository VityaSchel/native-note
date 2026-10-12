import Foundation
import Testing

@testable import NativeNoteKit

/// The exit run again through `AppModel`: real save scheduling, the editor's selection, and typing while requests are in flight.
@MainActor @Suite(.timeLimit(.minutes(5)))
struct AppModelConvergenceTests {
	private final class Ledger {
		var written: Set<String> = []
		var superseded: Set<String> = []
		var count = 0
	}

	private func library(_ server: SyncServer, settings: SyncSettings?) async throws -> (AppModel, TestTransport) {
		let transport = TestTransport(server)
		let (model, _) = try await unlockedModel { directory in
			AppModel(directory: directory, scheduler: SaveScheduler(delay: .milliseconds(15)), makeTransport: { _ in transport }, syncDelay: .seconds(3600))
		}
		if let settings {
			let store = try #require(model.store)
			try await store.enableSync(settings, pin: 1)
			await model.startSync(store)
		}
		return (model, transport)
	}

	private func type(on model: AppModel, _ random: inout SeededGenerator, _ ledger: Ledger) {
		guard let note = model.notes.randomElement(using: &random) else { return }
		ledger.count += 1
		let text = "edit \(ledger.count)"
		model.selection = note.id
		ledger.superseded.insert(note.body)
		ledger.written.insert(text)
		model.edit(note.id, text)
	}

	@Test(arguments: [UInt64(0xa11_0001), 0xa11_0002])
	func modelsConvergeUnderLossKillsAndTypingMidRequest(seed: UInt64) async throws {
		let server = try SyncServer()
		let (first, firstTransport) = try await library(server, settings: nil)
		let phrase = try await first.prepareSync(server: server.url.absoluteString, apiKey: try String(contentsOf: server.data.appending(path: "api-key"), encoding: .utf8)).get()
		try #require(await first.finishSync(answers: phrase.checked.map { phrase.words[$0] }) == nil)
		let (second, secondTransport) = try await library(server, settings: try await first.store?.syncSettings())
		let models = [(first, firstTransport), (second, secondTransport)]
		var random = SeededGenerator(seed: seed)
		let ledger = Ledger()

		for _ in 0 ..< 160 {
			let (model, transport) = models[Int.random(in: 0 ..< 2, using: &random)]
			switch Int.random(in: 0 ..< 10, using: &random) {
			case 0 ..< 3:
				type(on: model, &random, ledger)
			case 3:
				ledger.count += 1
				let text = "new \(ledger.count)"
				ledger.written.insert(text)
				await model.createNote()
				model.edit(try #require(model.selection), text)
			case 4 where !model.notes.isEmpty:
				let note = try #require(model.notes.randomElement(using: &random))
				ledger.superseded.insert(note.body)
				await model.delete(note.id)
			default:
				let fault: TestTransport.Fault = switch Int.random(in: 0 ..< 8, using: &random) {
				case 0: .dropRequest
				case 1: .dropResponse
				case 2: .killServer
				default: .none
				}
				transport.failNext(fault)
				var typing = Int.random(in: 0 ..< 2, using: &random)
				var nested = SeededGenerator(seed: random.next())
				transport.whilePosting = { [ledger] in
					guard typing > 0 else { return }
					typing -= 1
					self.type(on: model, &nested, ledger)
				}
				await model.syncNow()
				transport.whilePosting = nil
			}
		}

		for _ in 0 ..< 3 {
			for (model, _) in models { await model.syncNow() }
		}
		for (model, _) in models {
			await model.flushPendingSaves()
			#expect(model.syncStatus.phase == .idle, "\(model.syncStatus.phase)")
		}
		let firstLive = Set(try await #require(first.store).liveNotes().map(\.body))
		let secondLive = Set(try await #require(second.store).liveNotes().map(\.body))
		#expect(firstLive == secondLive)
		#expect(Set(first.notes.map(\.body)) == firstLive)
		#expect(Set(second.notes.map(\.body)) == secondLive)
		let lost = ledger.written.subtracting(firstLive).subtracting(ledger.superseded)
		#expect(lost.isEmpty, "lost writes: \(lost.sorted())")
	}
}
