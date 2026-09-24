import Foundation
import Testing

@testable import NativeNoteKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LibraryExchangeTests {
	private let alarm = Alarm()

	private func library(_ bodies: [String]) async throws -> (AppModel, URL) {
		let (model, directory) = try await unlockedModel { [alarm] directory in
			AppModel(directory: directory, scheduler: SaveScheduler(sleep: alarm.sleep), exportParameters: .init(m: 1024, t: 1, p: 1))
		}
		try await fill(model, with: bodies)
		return (model, directory)
	}

	private func exportFile(in directory: URL) -> URL {
		directory.appending(path: "export.nnexport")
	}

	@Test func anExportRestoresEveryNoteIntoAnEmptyLibrary() async throws {
		let (source, sourceDirectory) = try await library(["Shopping\nbread", "Trip\nferry at 07:20", ""])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = exportFile(in: sourceDirectory)

		#expect(await source.exportLibrary(to: file, passphrase: nil))
		let summary = await target.importLibrary(from: file, passphrase: nil)

		#expect(summary == ImportSummary(added: 3))
		let restored = target.notes.sorted { $0.id.uuidString < $1.id.uuidString }
		let original = source.notes.sorted { $0.id.uuidString < $1.id.uuidString }
		#expect(restored.map(\.id) == original.map(\.id))
		#expect(restored.map(\.body) == original.map(\.body))
		#expect(restored.map(\.createdAt.epochMilliseconds) == original.map(\.createdAt.epochMilliseconds))
		#expect(restored.map(\.updatedAt.epochMilliseconds) == original.map(\.updatedAt.epochMilliseconds))
		let disk = try await observer(of: targetDirectory)
		#expect(try await disk.liveNotes().count == 3)
	}

	@Test func anEncryptedExportOpensOnlyWithItsPassphrase() async throws {
		let (source, sourceDirectory) = try await library(["Secret\nplans"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = exportFile(in: sourceDirectory)

		#expect(await source.exportLibrary(to: file, passphrase: "correct staple"))
		#expect(AppModel.isEncryptedExport(at: file))
		#expect(try Data(contentsOf: file).range(of: Data("Secret".utf8)) == nil)

		#expect(await target.importLibrary(from: file, passphrase: "wrong staple") == nil)
		#expect(target.failure == .wrongExportPassphrase)
		#expect(target.notes.isEmpty)

		#expect(await target.importLibrary(from: file, passphrase: "correct staple") == ImportSummary(added: 1))
		#expect(target.notes.map(\.body) == ["Secret\nplans"])
	}

	@Test func aPlainExportIsNotReportedAsEncrypted() async throws {
		let (source, directory) = try await library(["Plain"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)

		#expect(await source.exportLibrary(to: file, passphrase: nil))

		#expect(!AppModel.isEncryptedExport(at: file))
	}

	@Test func importingTheSameExportAgainChangesNothing() async throws {
		let (model, directory) = try await library(["Shopping\nbread", "Trip"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		let before = model.notes

		#expect(await model.importLibrary(from: file, passphrase: nil) == ImportSummary(unchanged: 2))
		#expect(model.notes == before)
		#expect(model.conflicts.isEmpty)
	}

	@Test func aNoteChangedSinceTheExportAsksWhichToKeep() async throws {
		let (model, directory) = try await library(["Shopping\nbread"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		let id = try #require(model.notes.first?.id)
		model.edit(id, "Shopping\nbread and milk")

		#expect(await model.importLibrary(from: file, passphrase: nil) == ImportSummary(conflicting: 1))

		let conflict = try #require(model.conflicts.first)
		#expect(conflict.mine.body == "Shopping\nbread and milk")
		#expect(conflict.theirs.body == "Shopping\nbread")
		await model.resolve(conflict, .keepMine)
		#expect(model.conflicts.isEmpty)
		#expect(model.notes.first?.body == "Shopping\nbread and milk")
	}

	@Test func keepingTheirsSavesTheExportedTextAsANewEdit() async throws {
		let (model, directory) = try await library(["Shopping\nbread"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		let id = try #require(model.notes.first?.id)
		model.edit(id, "Shopping\nbread and milk")
		await model.flushPendingSaves()
		await model.importLibrary(from: file, passphrase: nil)
		let resolving = Date()

		await model.resolve(try #require(model.conflicts.first), .keepTheirs)

		#expect(model.conflicts.isEmpty)
		let kept = try #require(model.notes.first)
		#expect(kept.body == "Shopping\nbread")
		#expect(kept.updatedAt >= resolving)
		let disk = try #require(try await observer(of: directory).note(id: id))
		#expect(disk.body == "Shopping\nbread")
		#expect(disk.updatedAt.epochMilliseconds == kept.updatedAt.epochMilliseconds)
	}

	@Test func resolvingOneConflictLeavesTheOthers() async throws {
		let (model, directory) = try await library(["Shopping", "Trip"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		for note in model.notes { model.edit(note.id, note.body + " changed") }
		await model.importLibrary(from: file, passphrase: nil)
		try #require(model.conflicts.count == 2)

		await model.resolve(model.conflicts[0], .keepMine)

		#expect(model.conflicts.count == 1)
	}

	@Test func aSecondImportWaitsUntilTheConflictsAreResolved() async throws {
		let (model, directory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		model.edit(try #require(model.notes.first?.id), "Shopping list")
		await model.importLibrary(from: file, passphrase: nil)

		#expect(await model.importLibrary(from: file, passphrase: nil) == nil)
		#expect(model.conflicts.count == 1)
	}

	@Test func twoImportsAtOnceAddEachNoteOnce() async throws {
		let (source, sourceDirectory) = try await library(["Shopping", "Trip", "Plans"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (model, directory) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: sourceDirectory)
		#expect(await source.exportLibrary(to: file, passphrase: nil))

		async let first = model.importLibrary(from: file, passphrase: nil)
		async let second = model.importLibrary(from: file, passphrase: nil)
		let summaries = await [first, second]

		#expect(summaries.compactMap(\.self) == [ImportSummary(added: 3)])
		#expect(Set(model.notes.map(\.id)).count == 3)
		#expect(model.notes.count == 3)
	}

	@Test func lockingDuringAnImportReportsWhatWasLeft() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (model, directory) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: sourceDirectory)
		#expect(await source.exportLibrary(to: file, passphrase: nil))
		let started = DispatchSemaphore(value: 0)
		let gate = DispatchSemaphore(value: 0)
		let blocker = Task.detached { try await BlockingWork.run { started.signal(); gate.wait() } }
		await Task.detached { hold(started) }.value

		let importing = Task { await model.importLibrary(from: file, passphrase: nil) }
		await settle { model.isImporting }
		await model.lock()
		gate.signal()
		try await blocker.value

		#expect(await importing.value == ImportSummary(notImported: 1))
		#expect(model.failure == nil)
		#expect(model.notes.isEmpty)
	}

	@Test func anEncryptedExportCarriesTheModelsParameters() async throws {
		let (model, directory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)

		#expect(await model.exportLibrary(to: file, passphrase: "correct staple"))

		let expected = ExportEnvelope.header(parameters: .init(m: 1024, t: 1, p: 1), salt: Data())
		#expect(try Data(contentsOf: file).prefix(expected.count) == expected)
	}

	@Test func exportsUseTheArgon2FloorByDefault() async throws {
		let (model, directory) = try await unlockedModel(alarm: alarm)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)

		#expect(await model.exportLibrary(to: file, passphrase: "correct staple"))

		let expected = ExportEnvelope.header(parameters: Argon2.floor, salt: Data())
		#expect(try Data(contentsOf: file).prefix(expected.count) == expected)
	}

	@Test func anImportThatCannotReadTheLibraryStopsAndSaysSo() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (model, directory) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: sourceDirectory)
		#expect(await source.exportLibrary(to: file, passphrase: nil))
		try await connection(to: directory).execute("DROP TABLE note")

		#expect(await model.importLibrary(from: file, passphrase: nil) == nil)
		#expect(model.failure != nil)
	}

	@Test func aMissingFileIsNotAnEncryptedExport() {
		#expect(!AppModel.isEncryptedExport(at: temporaryDirectory().appending(path: "gone.nnexport")))
	}

	@Test func aFileTooLargeToBeAnExportIsRefusedUnread() async throws {
		let (model, directory) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		FileManager.default.createFile(atPath: file.path, contents: nil)
		let handle = try FileHandle(forWritingTo: file)
		try handle.truncate(atOffset: UInt64(LibraryArchive.maximumSize) + 1)
		try handle.close()

		#expect(await model.importLibrary(from: file, passphrase: nil) == nil)
		#expect(model.failure == .unexpected("The file is too large to be a Native Note export."))
	}

	@Test func aNoteDeletedHereIsNotBroughtBack() async throws {
		let (model, directory) = try await library(["Gone soon"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		await model.deleteSelected()

		#expect(await model.importLibrary(from: file, passphrase: nil) == ImportSummary(deletedHere: 1))
		#expect(model.notes.isEmpty)
	}

	@Test func theExportCarriesEditsNotYetSaved() async throws {
		let (source, sourceDirectory) = try await library(["Draft"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = exportFile(in: sourceDirectory)
		source.edit(try #require(source.notes.first?.id), "Draft\ntyped a moment ago")

		#expect(await source.exportLibrary(to: file, passphrase: nil))
		await target.importLibrary(from: file, passphrase: nil)

		#expect(target.notes.map(\.body) == ["Draft\ntyped a moment ago"])
	}

	@Test func aFileThatIsNotAnExportSaysSo() async throws {
		let (model, directory) = try await library([])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		try Data("hello".utf8).write(to: file)

		#expect(await model.importLibrary(from: file, passphrase: nil) == nil)
		#expect(model.failure == .unexpected("This file is not a Native Note export, or it is damaged."))
	}

	@Test func lockingDropsUnresolvedConflicts() async throws {
		let (model, directory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = exportFile(in: directory)
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		model.edit(try #require(model.notes.first?.id), "Shopping list")
		await model.importLibrary(from: file, passphrase: nil)
		try #require(!model.conflicts.isEmpty)

		await model.lock()

		#expect(model.conflicts.isEmpty)
	}
}

private func hold(_ semaphore: DispatchSemaphore) {
	semaphore.wait()
}
