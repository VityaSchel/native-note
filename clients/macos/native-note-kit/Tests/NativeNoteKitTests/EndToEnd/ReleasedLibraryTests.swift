import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.scratch, .timeLimit(.minutes(5)))
struct ReleasedLibraryTests {
	private static let password = "Crème brûlée at dusk"
	private static let notes: Set<[String]> = [
		["Shopping", "Shopping\nquartz, bread, and a new kettle"],
		["Crème brûlée", "Crème brûlée\nsix yolks, cream, one vanilla bean"],
		["Standup", "Standup\nshipped the storage layer"],
		["Встреча с командой", "Встреча с командой\nобсудить выпуск в пятницу"],
		["Trip plan", "Trip plan\nferry at 07:20\n- passport\n- charger\n- 🎒 day pack"],
		["Reading list", "Reading list\nRFC 9106, then the SQLCipher design doc"],
		["買い物リスト", "買い物リスト\n牛乳、卵、パン"],
	]

	private func copiedLibrary() throws -> URL {
		let fixture = try #require(Bundle.module.url(forResource: "fixtures", withExtension: nil)).appending(path: "library-0.1.0")
		let directory = temporaryDirectory()
		try FileManager.default.copyItem(at: fixture, to: directory)
		return directory
	}

	private func locked(_ directory: URL) -> AppModel {
		let model = AppModel.testing(in: directory, keyStore: FakeKeyStore(available: false), records: FileUnlockRecordStore(directory: directory))
		model.start()
		return model
	}

	private func search(_ model: AppModel, for text: String) async -> [String] {
		model.search = text
		await model.runSearch()
		return model.groups.flatMap(\.notes).map(\.title)
	}

	@Test func aLibraryWrittenByVersion010UnlocksWithItsPasswordFindsItsNotesAndKeepsAnEdit() async throws {
		let directory = try copiedLibrary()
		let model = locked(directory)
		try #require(model.phase == .locked)

		#expect(await model.submit(password: "Creme brulee at dusk") == .wrongPassword)
		#expect(await model.submit(password: Self.password) == nil)
		#expect(model.notes.count == Self.notes.count)
		#expect(Set(model.notes.map { [$0.title, $0.body] }) == Self.notes)
		#expect(await search(model, for: "brulee") == ["Crème brûlée"])
		#expect(await search(model, for: "ОБСУДИТЬ") == ["Встреча с командой"])
		#expect(await search(model, for: "shipped storage") == ["Standup"])
		#expect(await search(model, for: "paperwork").isEmpty)
		#expect(await search(model, for: "hunter2").isEmpty)

		let recipe = try #require(model.notes.first { $0.title == "Crème brûlée" }).id
		model.edit(recipe, "Crème brûlée\nseven yolks, cream, one vanilla bean")
		await model.close()
		let reopened = locked(directory)

		#expect(await reopened.submit(password: Self.password) == nil)
		#expect(reopened.notes.count == Self.notes.count)
		#expect(reopened.notes.first { $0.id == recipe }?.body == "Crème brûlée\nseven yolks, cream, one vanilla bean")
		#expect(await search(reopened, for: "seven") == ["Crème brûlée"])
		#expect(await search(reopened, for: "six").isEmpty)
		#expect(try await #require(reopened.store).integrityCheck() == "ok")
	}
}

private extension NoteStore {
	func integrityCheck() throws -> String? {
		try connection.execute("INSERT INTO note_fts (note_fts) VALUES ('integrity-check')")
		return try connection.scalar("PRAGMA integrity_check")
	}
}
