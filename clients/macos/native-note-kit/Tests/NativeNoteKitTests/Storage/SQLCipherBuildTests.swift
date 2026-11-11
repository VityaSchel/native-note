import Foundation
import Testing

@testable import NativeNoteKit

struct SQLCipherBuildTests {
	private func connection() throws -> (SQLiteConnection, URL) {
		let url = temporaryDatabase()
		try makeDirectory(for: url)
		return (try SQLiteConnection(url: url, rawKey: databaseKey), url)
	}

	@Test func isSQLCipher4_17OnCommonCrypto() throws {
		let (connection, url) = try connection()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		#expect(try connection.scalar("PRAGMA cipher_version") == "4.17.0 community")
		#expect(try connection.scalar("PRAGMA cipher_provider") == "commoncrypto")
	}

	@Test func keepsThePrebuiltDefaultsWithFTS5AsTheOnlyExtra() throws {
		let (connection, url) = try connection()
		defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

		let statement = try connection.prepare("PRAGMA compile_options")
		var options: [String] = []
		while try statement.step() { options.append(statement.string(0)) }

		#expect(options.filter { !$0.hasPrefix("COMPILER=") } == [
			"ATOMIC_INTRINSICS=1", "DEFAULT_AUTOVACUUM", "DEFAULT_CACHE_SIZE=-2000", "DEFAULT_FILE_FORMAT=4",
			"DEFAULT_JOURNAL_SIZE_LIMIT=1048576", "DEFAULT_MMAP_SIZE=0", "DEFAULT_PAGE_SIZE=4096", "DEFAULT_PCACHE_INITSZ=20",
			"DEFAULT_RECURSIVE_TRIGGERS", "DEFAULT_SECTOR_SIZE=4096", "DEFAULT_SYNCHRONOUS=2", "DEFAULT_WAL_AUTOCHECKPOINT=1000",
			"DEFAULT_WAL_SYNCHRONOUS=1", "DEFAULT_WORKER_THREADS=0", "DIRECT_OVERFLOW_READ", "ENABLE_FTS5", "ENABLE_MEMORY_MANAGEMENT",
			"EXTRA_INIT=sqlcipher_extra_init", "EXTRA_SHUTDOWN=sqlcipher_extra_shutdown", "HAS_CODEC", "MALLOC_SOFT_LIMIT=1024",
			"MAX_ATTACHED=10", "MAX_COLUMN=2000", "MAX_COMPOUND_SELECT=500", "MAX_DEFAULT_PAGE_SIZE=8192", "MAX_EXPR_DEPTH=1000",
			"MAX_FUNCTION_ARG=1000", "MAX_LENGTH=1000000000", "MAX_LIKE_PATTERN_LENGTH=50000", "MAX_MMAP_SIZE=0x7fff0000",
			"MAX_PAGE_COUNT=0xfffffffe", "MAX_PAGE_SIZE=65536", "MAX_SQL_LENGTH=1000000000", "MAX_TRIGGER_DEPTH=1000",
			"MAX_VARIABLE_NUMBER=99999", "MAX_VDBE_OP=250000000", "MAX_WORKER_THREADS=8", "MUTEX_PTHREADS", "OMIT_DEPRECATED",
			"OMIT_JSON", "OMIT_LOAD_EXTENSION", "OMIT_SHARED_CACHE", "SYSTEM_MALLOC", "TEMP_STORE=2", "THREADSAFE=1", "USE_URI",
		])
	}
}
