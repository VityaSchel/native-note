import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

private extension NoteStore {
	func store(_ value: Data, as key: String) throws {
		try connection.execute("INSERT INTO meta (k, v) VALUES ('\(key)', x'\(NativeNoteKit.Hex.string(value))') ON CONFLICT(k) DO UPDATE SET v = excluded.v")
	}
}

@Suite(.scratch)
struct SyncMetadataTests {
	private let settings = SyncSettings(server: URL(string: "http://notes.example/")!, apiKey: SymmetricKey(size: .bits256), contentKey: sharedContentKey)

	private func syncedStore() async throws -> NoteStore {
		let store = try await openStore(at: temporaryDatabase())
		try await store.enableSync(settings, pin: 3)
		return store
	}

	@Test(arguments: [0, 1, 3, 4])
	func aLastPulledMarkTooShortToHoldAnIdAndAVersionReadsAsNone(length: Int) async throws {
		let store = try await syncedStore()
		try await store.store(Data(repeating: 0xab, count: length), as: "lastPulled")

		#expect(try await store.lastPulled() == nil)
		let kept = try #require(try await store.keptLibrary())
		#expect(kept.mark == nil)
		#expect(kept.pin == 3)
	}

	@Test func aWholeLastPulledMarkSplitsIntoItsIdAndVersion() async throws {
		let store = try await syncedStore()
		let blindedId = Data((1 ... 16).map { UInt8($0) })
		try await store.store(blindedId + Data([0, 0, 1, 2]), as: "lastPulled")

		#expect(try await store.lastPulled() == PullMark(blindedId: blindedId, v: 258))
		#expect(try await store.keptLibrary()?.mark == PullMark(blindedId: blindedId, v: 258))
	}

	@Test(arguments: [
		Data(),
		Data("nowhere".utf8),
		Data("notes.example:8080".utf8),
		Data("ftp://notes.example/".utf8),
		Data("http://".utf8),
		Data("http://notes example/".utf8),
		Data([0xff, 0xfe, 0x00]),
	])
	func aStoredServerAddressThatIsNotAnHTTPAddressIsUnreadableNotAbsent(address: Data) async throws {
		let store = try await syncedStore()
		try await store.store(address, as: "server")

		await #expect(throws: NoteStore.ServerAddressUnreadable.self) { try await store.syncSettings() }
		#expect(try await store.keptLibrary()?.contentKey == sharedContentKey)
	}

	@Test func aStoredServerAddressSurvivesAsWritten() async throws {
		let store = try await syncedStore()

		#expect(try await store.syncSettings()?.server == settings.server)
	}
}
