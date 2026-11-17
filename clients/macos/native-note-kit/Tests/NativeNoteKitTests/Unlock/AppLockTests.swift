import Foundation
import Testing

@testable import NativeNoteKit

@Suite(.scratch)
struct AppLockTests {
	private final class Flushes {
		struct Flush {
			let path: String
			let held: UnlockRecord?
			let current: UnlockRecord?
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
			all.append(Flush(path: path, held: try? UnlockRecords.decode(Data(contentsOf: URL(fileURLWithPath: path))), current: try? UnlockRecords.decode(Data(contentsOf: current))))
			try AppLock.fullSync(descriptor)
		}

		func replaced(_ old: UnlockRecord?, with new: UnlockRecord, in directory: URL) -> Bool {
			let folder = directory.resolvingSymlinksInPath().path
			guard all.count == 2 else { return false }
			return all[0].path.hasPrefix(folder + "/.app-lock.plist.") && all[0].held == new && all[0].current == old
				&& all[1].path == folder && all[1].current == new
		}
	}

	@Test func aRecordFileReachesTheDiskBeforeItReplacesTheOldOneAndTheRenameAfter() throws {
		let directory = temporaryDirectory()
		let url = AppLock.recordFile(in: directory)
		try FileUnlockRecordStore(directory: directory).write(.fast)
		let flushes = Flushes(current: url)

		try AppLock.durablyReplace(url, with: UnlockRecords.encode(.sample), sync: flushes.record)

		#expect(flushes.replaced(.fast, with: .sample, in: directory))
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["app-lock.plist"])
		#expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
	}

	@Test func aRecordFileThatCannotReachTheDiskLeavesTheOldOneAndNoLeftovers() throws {
		let directory = temporaryDirectory()
		let records = FileUnlockRecordStore(directory: directory)
		try records.write(.fast)

		#expect(throws: POSIXError.self) {
			try AppLock.durablyReplace(AppLock.recordFile(in: directory), with: Data("new".utf8)) { _ in throw POSIXError(.EIO) }
		}

		#expect(try records.read() == .fast)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["app-lock.plist"])
	}

	@Test func writesPrivatelyAndReadsBack() throws {
		let directory = temporaryDirectory()
		let records = FileUnlockRecordStore(directory: directory)

		try records.write(.sample)

		let fileMode = try FileManager.default.attributesOfItem(atPath: AppLock.recordFile(in: directory).path)[.posixPermissions] as? NSNumber
		let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
		#expect(fileMode?.int16Value == 0o600)
		#expect(directoryMode?.int16Value == 0o700)
		#expect(try records.read() == .sample)
	}

	@Test func refusesARecordFromAFutureVersion() throws {
		let directory = temporaryDirectory()
		var future = UnlockRecord.sample
		future.version = 2
		try AppLock.durablyReplace(AppLock.recordFile(in: directory), with: UnlockRecords.encode(future))

		#expect(throws: AppLock.Unreadable.unsupportedVersion(2)) { try FileUnlockRecordStore(directory: directory).read() }
	}

	@Test func readsNothingWhenTheAppHasNeverBeenSetUpAndDeletesOnlyTheRecord() throws {
		let directory = temporaryDirectory()
		let records = FileUnlockRecordStore(directory: directory)
		#expect(try records.read() == nil)
		try records.delete()

		try records.write(.sample)
		FileManager.default.createFile(atPath: AppLock.databaseFile(in: directory).path, contents: Data("x".utf8))
		try records.delete()

		#expect(try records.read() == nil)
		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["notes.db"])
	}

	@Test func settingADatabaseAsideMovesItsSidecarsWithIt() throws {
		let directory = temporaryDirectory()
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

	@Test func erasingTheDatabaseRemovesOnlyItsFiles() throws {
		let directory = temporaryDirectory()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let database = AppLock.databaseFile(in: directory)
		let library = [database, walFile(of: database), shmFile(of: database), directory.appending(path: "notes-set-aside-x-1.db")]
		for file in library + [AppLock.recordFile(in: directory), directory.appending(path: "export.zip"), directory.appending(path: "notes.txt")] {
			FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
		}

		try AppLock.eraseDatabase(in: directory)

		#expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["app-lock.plist", "export.zip", "notes.txt"])
	}
}
