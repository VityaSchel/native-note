import Foundation
import Testing

@testable import NativeNoteKit

private enum AtRest {
	static let sqliteHeader = Data("SQLite format 3".utf8)

	static func sidecars(in directory: URL) throws -> [String] {
		try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }
	}

	static func chiSquare(_ bytes: Data) -> Double {
		var counts = [Int](repeating: 0, count: 256)
		for byte in bytes { counts[Int(byte)] += 1 }
		let expected = Double(bytes.count) / 256
		return counts.reduce(0) { $0 + (Double($1) - expected) * (Double($1) - expected) / expected }
	}
}

extension LibraryEndToEndTests {
	@Test func aLockedLibraryIsIndistinguishableFromRandomOnDisk() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery")
		defer { try? FileManager.default.removeItem(at: directory) }
		#expect(try !AtRest.sidecars(in: directory).isEmpty)

		await model.lock()

		#expect(try AtRest.sidecars(in: directory).isEmpty)
		let database = try Data(contentsOf: AppLock.databaseFile(in: directory))
		#expect(database.count > 1_000_000)
		#expect(!database.starts(with: AtRest.sqliteHeader))
		#expect(AtRest.chiSquare(database) < 400)
		let compressed = try (database as NSData).compressed(using: .lzfse)
		#expect(compressed.length >= database.count * 99 / 100)
		for body in corpus.prefix(40) {
			let words = body.split(whereSeparator: \.isWhitespace).filter { $0.utf8.count >= 8 }
			for word in words.prefix(2) {
				#expect(database.range(of: Data(word.utf8)) == nil, "\(word)")
			}
		}
	}

	@Test func quittingClosesTheDatabaseLikeLocking() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery", filled: false)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: Array(corpus.prefix(50)))
		model.edit(try #require(model.selection), "typed just before quitting")

		await model.close()

		#expect(try AtRest.sidecars(in: directory).isEmpty)
		let relaunched = try await launch(in: directory, password: "correct horse battery")
		#expect(relaunched.notes.contains { $0.body == "typed just before quitting" })
		await relaunched.lock()
	}

	@Test func aCrashLeavesTheSidecarsUntilTheNextLock() async throws {
		let (model, directory) = try await realLibrary(password: "correct horse battery", filled: false)
		defer { try? FileManager.default.removeItem(at: directory) }
		try await fill(model, with: Array(corpus.prefix(50)))
		let crashed = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: crashed) }
		try FileManager.default.copyItem(at: directory, to: crashed)
		await model.lock()
		#expect(try !AtRest.sidecars(in: crashed).isEmpty)

		let relaunched = try await launch(in: crashed, password: "correct horse battery")
		#expect(relaunched.notes.count == 50)
		await relaunched.lock()

		#expect(try AtRest.sidecars(in: crashed).isEmpty)
	}
}
