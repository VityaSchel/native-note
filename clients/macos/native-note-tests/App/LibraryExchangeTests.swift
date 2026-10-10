import Foundation
import Testing

@testable import NativeNote
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

	@Test func aPlainExportImportsAtOnce() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = sourceDirectory.appending(path: "export.zip")
		#expect(await source.exportLibrary(to: file, passphrase: nil))
		let exchange = LibraryExchange(model: target)

		await exchange.receive(file)

		#expect(exchange.sheet == nil)
		#expect(exchange.lastImport == ImportSummary(added: 1))
		#expect(exchange.showsSummary)
		#expect(target.notes.map(\.body) == ["Shopping"])
		exchange.showsSummary = false
		#expect(exchange.lastImport == nil)
	}

	@Test func anEncryptedExportAsksForItsPassphraseFirst() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = sourceDirectory.appending(path: "export.nnexport")
		#expect(await source.exportLibrary(to: file, passphrase: "correct staple"))
		let exchange = LibraryExchange(model: target)

		await exchange.receive(file)
		#expect(exchange.sheet == .passphrase)
		#expect(target.notes.isEmpty)

		await exchange.importPending(passphrase: "correct staple")
		#expect(exchange.sheet == nil)
		#expect(exchange.lastImport == ImportSummary(added: 1))
	}

	@Test func cancellingThePassphraseImportsNothing() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = sourceDirectory.appending(path: "export.nnexport")
		#expect(await source.exportLibrary(to: file, passphrase: "correct staple"))
		let exchange = LibraryExchange(model: target)
		await exchange.receive(file)

		exchange.dismiss(.passphrase)
		await exchange.importPending(passphrase: "correct staple")

		#expect(exchange.sheet == nil)
		#expect(exchange.lastImport == nil)
		#expect(target.notes.isEmpty)
	}

	@Test func theSummarySaysWhatHappened() {
		#expect(ImportSummary(added: 1).message == "Imported 1 note.")
		#expect(ImportSummary(added: 3).message == "Imported 3 notes.")
		#expect(ImportSummary(added: 0, skipped: 2, notImported: 5).message == "Imported 0 notes. 2 already here or deleted here, 5 not imported because Native Note locked.")
		#expect(ImportSummary(added: 1, notImported: 5).message == "Imported 1 note. 5 not imported because Native Note locked.")
	}

	@Test func cancellingTheExportSheetClosesIt() {
		let exchange = LibraryExchange(model: .previewing([]))
		exchange.isExporting = true
		#expect(exchange.sheet == .export)
		#expect(!exchange.isIdle)

		exchange.dismiss(.export)

		#expect(exchange.sheet == nil)
		#expect(exchange.isIdle)
	}

	@Test func commandsWaitForUnlockAndForTheOpenSheet() async throws {
		let (model, directory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let exchange = LibraryExchange(model: model)
		#expect(exchange.acceptsCommands)
		#expect(exchange.canExchange)

		exchange.isExporting = true
		#expect(!exchange.acceptsCommands)
		#expect(!exchange.canExchange)
		exchange.dismiss(.export)
		#expect(exchange.acceptsCommands)
		#expect(exchange.canExchange)

		await model.lock()
		#expect(!exchange.acceptsCommands)
		#expect(!exchange.canExchange)
	}

	@Test func anImportHoldsExportAndImportButNotEditing() async throws {
		let (model, directory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appending(path: "Native Note.zip")
		#expect(await model.exportLibrary(to: file, passphrase: nil))
		let exchange = LibraryExchange(model: model)

		let importing = Task { await exchange.receive(file) }
		for _ in 0 ..< 1_000 where !exchange.isImporting {
			await Task.yield()
		}
		try #require(exchange.isImporting)

		#expect(exchange.acceptsCommands)
		#expect(!exchange.canExchange)
		await importing.value
		#expect(exchange.canExchange)
	}

	@Test func closingASheetFromOutsideDismissesIt() {
		let exchange = LibraryExchange(model: .previewing([]))
		exchange.isExporting = true

		exchange.presentedSheet = nil

		#expect(exchange.sheet == nil)
	}

	@Test func aWrongPassphraseKeepsTheSheetOpenToTryAgain() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = sourceDirectory.appending(path: "export.nnexport")
		#expect(await source.exportLibrary(to: file, passphrase: "correct staple"))
		let exchange = LibraryExchange(model: target)
		await exchange.receive(file)

		await exchange.importPending(passphrase: "wrong staple")
		#expect(exchange.sheet == .passphrase)
		#expect(exchange.passphraseRefused)
		#expect(target.failure?.alert == nil)

		await exchange.importPending(passphrase: "correct staple")
		#expect(exchange.sheet == nil)
		#expect(!exchange.passphraseRefused)
		#expect(exchange.lastImport == ImportSummary(added: 1))
	}

	@Test func cancellingAfterAWrongPassphraseForgetsIt() async throws {
		let (source, sourceDirectory) = try await library(["Shopping"])
		defer { try? FileManager.default.removeItem(at: sourceDirectory) }
		let (target, targetDirectory) = try await library([])
		defer { try? FileManager.default.removeItem(at: targetDirectory) }
		let file = sourceDirectory.appending(path: "export.nnexport")
		#expect(await source.exportLibrary(to: file, passphrase: "correct staple"))
		let exchange = LibraryExchange(model: target)
		await exchange.receive(file)
		await exchange.importPending(passphrase: "wrong staple")

		exchange.dismiss(.passphrase)

		#expect(exchange.sheet == nil)
		#expect(target.failure == nil)
	}
}
