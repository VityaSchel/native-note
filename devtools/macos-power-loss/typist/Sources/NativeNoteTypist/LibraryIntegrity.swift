import Foundation

@testable import NativeNoteKit

nonisolated enum LibraryIntegrity {
	static func check(libraryAt directory: URL, password: String) async throws -> String {
		guard let record = try FileUnlockRecordStore(directory: directory).read() else { throw Unlock.Failure.neverSetUp }
		return try await BlockingWork.run {
			let key = try Unlock.databaseKey(password: password, record: record)
			let connection = try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: key, create: false)
			return try connection.scalar("PRAGMA integrity_check") ?? ""
		}
	}

	static func walCheckpoints(libraryAt directory: URL) -> Int? {
		guard let wal = FileHandle(forReadingAtPath: AppLock.databaseFile(in: directory).path + "-wal") else { return nil }
		defer { try? wal.close() }
		guard let header = try? wal.read(upToCount: 16), header.count == 16 else { return nil }
		guard [0x377F_0682, 0x377F_0683].contains(UInt32(bigEndianBytes: header.prefix(4))) else { return nil }
		return Int(UInt32(bigEndianBytes: header.suffix(4)))
	}
}
