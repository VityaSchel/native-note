import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@MainActor
struct SyncEngineTests {
	@Test func aNoteWrittenOnOneDeviceArrivesOnAnotherWithItsTimesAndVersion() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let id = try await a.write("Groceries\nmilk")

		try await a.sync()
		try await b.sync()

		let sent = try #require(try await a.note(id))
		let received = try #require(try await b.note(id))
		#expect((received.body, received.createdAt, received.updatedAt, received.v) == (sent.body, sent.createdAt, sent.updatedAt, 1))
		#expect(!sent.dirty && !received.dirty)
		#expect(try await a.store.since() == 1)
		#expect(try await b.store.since() == 1)
	}

	@Test func concurrentEditsKeepTheLosingTextAsANewNoteAndBothDevicesConverge() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let id = try await a.write("draft")
		try await a.sync()
		try await b.sync()

		try await a.write("edited on A", to: id)
		try await b.write("edited on B", to: id)
		try await a.sync()
		let applied = try await b.sync()

		let copy = try #require(applied.copies[id])
		#expect(try await b.live() == [id: "edited on A", copy: "edited on B"])
		try await b.sync()
		try await a.sync()
		let converged = try await b.live()
		#expect(try await a.live() == converged)
		#expect(try await a.dirty.isEmpty)
		#expect(try await b.dirty.isEmpty)
	}

	@Test func matchingTextMakesNoCopy() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let id = try await a.write("same words")
		try await b.write("same words", to: id)

		try await a.sync()
		let applied = try await b.sync()

		#expect(applied.copies.isEmpty)
		#expect(try await b.live() == [id: "same words"])
		#expect(try await b.dirty.isEmpty)
	}

	@Test func aDeletionReachesTheOtherDeviceAndAConcurrentEditOutlivesIt() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let kept = try await a.write("kept")
		let gone = try await a.write("gone")
		try await a.sync()
		try await b.sync()

		try await a.delete(gone)
		try await a.delete(kept)
		try await b.write("kept, edited on B", to: kept)
		try await b.sync()
		let applied = try await a.sync()
		try await b.sync()

		#expect(applied.copies.isEmpty)
		#expect(try await a.live() == [kept: "kept, edited on B"])
		#expect(try await b.live() == [kept: "kept, edited on B"])
		#expect(try await b.note(gone)?.deleted == true)
	}

	@Test func aPulledDeletionOverUnpushedTextKeepsTheTextAsANewNote() async throws {
		let server = try SyncServer()
		let a = try await SyncDevice(server)
		let b = try await SyncDevice(server)
		let id = try await a.write("shared")
		try await a.sync()
		try await b.sync()

		try await a.delete(id)
		try await a.sync()
		try await b.write("still needed", to: id)
		let applied = try await b.sync()

		let copy = try #require(applied.copies[id])
		#expect(try await b.live() == [copy: "still needed"])
		#expect(try await b.note(id)?.deleted == true)
		try await b.sync()
		try await a.sync()
		#expect(try await a.live() == [copy: "still needed"])
	}
}
