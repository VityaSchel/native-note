import Foundation

nonisolated public enum LibraryIntegrity {
	public static func check(libraryAt directory: URL, password: String) async throws -> String {
		let parameters = try AppLock.read(from: AppLock.currentFile(in: directory))
		return try await BlockingWork.run {
			let key = try Unlock.localDbKey(password: password, parameters: parameters)
			let connection = try SQLiteConnection(url: AppLock.databaseFile(in: directory), rawKey: key, create: false)
			return try connection.scalar("PRAGMA integrity_check") ?? ""
		}
	}

	public static func walCheckpoints(libraryAt directory: URL) -> Int? {
		guard let wal = FileHandle(forReadingAtPath: AppLock.databaseFile(in: directory).path + "-wal") else { return nil }
		defer { try? wal.close() }
		guard let header = try? wal.read(upToCount: 16), header.count == 16 else { return nil }
		let words = stride(from: 0, to: 16, by: 4).map { start in
			header.dropFirst(start).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
		}
		guard [0x377F_0682, 0x377F_0683].contains(words[0]) else { return nil }
		return Int(words[3])
	}
}
