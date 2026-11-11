import Foundation
import Testing

@testable import NativeNoteKit

struct AppLockTests {
	/// Each flush: what was flushed, what it held then, and what the current file held then.
	private final class Flushes {
		struct Flush {
			let path: String
			let held: UnlockParameters?
			let current: UnlockParameters?
		}

		private let current: URL
		private(set) var all: [Flush] = []

		init(current: URL) {
			self.current = current
		}

		func record(_ descriptor: Int32) throws {
			var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
			_ = fcntl(descriptor, F_GETPATH, &buffer)
			let path = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path
			all.append(Flush(path: path, held: try? AppLock.read(from: URL(fileURLWithPath: path)), current: try? AppLock.read(from: current)))
			try AppLock.fullSync(descriptor)
		}

		/// The new parameters were on disk in a temporary file while the old ones were still current, then the folder after the rename.
		func replaced(_ old: UnlockParameters?, with new: UnlockParameters, in directory: URL) -> Bool {
			let folder = directory.resolvingSymlinksInPath().path
			guard all.count == 2 else { return false }
			return all[0].path.hasPrefix(folder + "/.app-lock.plist.") && all[0].held == new && all[0].current == old
				&& all[1].path == folder && all[1].current == new
		}
	}

	@Test func aParameterFileReachesTheDiskBeforeItReplacesTheOldOneAndTheRenameAfter() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = AppLock.currentFile(in: directory)
		try AppLock.write(.fast, to: url)
		let flushes = Flushes(current: url)

		try AppLock.write(.sample, to: url, sync: flushes.record)

		#expect(flushes.replaced(.fast, with: .sample, in: directory))
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["app-lock.plist"])
		#expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
	}

	@Test func aPromotedRekeyReachesTheDiskBeforeItReplacesTheOldParameters() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try AppLock.write(.sample, to: AppLock.pendingRekeyFile(in: directory))
		let flushes = Flushes(current: AppLock.currentFile(in: directory))

		try AppLock.promoteRekey(in: directory, sync: flushes.record)

		#expect(flushes.replaced(.fast, with: .sample, in: directory))
		#expect(AppLock.parameterFiles(in: directory) == [AppLock.currentFile(in: directory)])
	}

	@Test func aParameterFileThatCannotReachTheDiskLeavesTheOldOneAndNoLeftovers() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = AppLock.currentFile(in: directory)
		try AppLock.write(.fast, to: url)

		#expect(throws: POSIXError.self) {
			try AppLock.durablyReplace(url, with: Data("new".utf8)) { _ in throw POSIXError(.EIO) }
		}

		#expect(try AppLock.read(from: url) == .fast)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["app-lock.plist"])
	}

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

	@Test func erasingRemovesOnlyTheLibraryFiles() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let database = AppLock.databaseFile(in: directory)
		let library = [AppLock.currentFile(in: directory), AppLock.pendingRekeyFile(in: directory), database, walFile(of: database), shmFile(of: database), directory.appending(path: "notes-set-aside-x-1.db")]
		for file in library + [directory.appending(path: "export.zip"), directory.appending(path: "notes.txt")] {
			FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
		}

		try AppLock.erase(in: directory)

		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["export.zip", "notes.txt"])
	}
}
