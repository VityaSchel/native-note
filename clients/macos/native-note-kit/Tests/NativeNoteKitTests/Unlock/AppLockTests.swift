import Foundation
import Testing

@testable import NativeNoteKit

struct AppLockTests {
	@Test func writesPrivatelyAndReadsBack() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(.sample, to: url)

		let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
		let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
		#expect(fileMode?.int16Value == 0o600)
		#expect(directoryMode?.int16Value == 0o700)
		#expect(try AppLock.read(from: url) == .sample)
	}

	@Test func refusesParametersFromAFutureVersion() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var future = UnlockParameters.sample
		future.version = 2
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(future, to: url)

		#expect(throws: AppLock.Unreadable.unsupportedVersion(2)) { try AppLock.read(from: url) }
		#expect(AppLock.parameterFiles(in: directory) == [url])
	}

	@Test func offersThePendingFileFirstButKeepsTheCurrentOneAsFallback() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let current = AppLock.currentFile(in: directory)
		let pending = AppLock.pendingRekeyFile(in: directory)

		try AppLock.write(.sample, to: current)
		#expect(AppLock.parameterFiles(in: directory) == [current])

		try AppLock.write(.sample, to: pending)
		#expect(AppLock.parameterFiles(in: directory) == [pending, current])
	}

	@Test func keepingTheCurrentFileDropsAStalePendingOne() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParameters.sample
		next.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))
		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))

		try AppLock.keep(AppLock.currentFile(in: directory), in: directory)

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == .sample)
	}

	@Test func keepingThePendingFilePromotesIt() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParameters.sample
		next.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))
		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))

		try AppLock.keep(AppLock.pendingRekeyFile(in: directory), in: directory)

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == next)
	}

	@Test func settingADatabaseAsideMovesItsSidecarsWithIt() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let database = AppLock.databaseFile(in: directory)
		for file in [database, walFile(of: database), shmFile(of: database)] {
			FileManager.default.createFile(atPath: file.path, contents: Data(file.lastPathComponent.utf8))
		}

		let aside = try AppLock.asideFile(for: database)

		try AppLock.setAside(database)

		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [aside.lastPathComponent, walFile(of: aside).lastPathComponent, shmFile(of: aside).lastPathComponent].sorted())
		#expect(try Data(contentsOf: walFile(of: aside)) == Data("notes.db-wal".utf8))
	}

	@Test func settingAsideWithoutADatabaseDoesNothing() throws {
		let directory = temporaryDirectory()

		try AppLock.setAside(AppLock.databaseFile(in: directory))

		#expect(!FileManager.default.fileExists(atPath: directory.path))
	}

	@Test func promotingARekeyLeavesExactlyOneFile() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParameters.sample
		next.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(.sample, to: AppLock.currentFile(in: directory))
		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))

		try AppLock.promoteRekey(in: directory)

		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
		#expect(try AppLock.read(from: AppLock.currentFile(in: directory)) == next)
		#expect(!FileManager.default.fileExists(atPath: AppLock.pendingRekeyFile(in: directory).path))
		let mode = try FileManager.default.attributesOfItem(atPath: AppLock.currentFile(in: directory).path)[.posixPermissions] as? NSNumber
		#expect(mode?.int16Value == 0o600)
	}

	@Test func reportsNothingWhenTheAppHasNeverBeenSetUp() {
		#expect(AppLock.parameterFiles(in: temporaryDirectory()).isEmpty)
	}
}
