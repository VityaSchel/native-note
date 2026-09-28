import Darwin
import Foundation
import Testing

@testable import PowerLossKit

struct BackingFileTests {
	@Test func aNewBackingFileIsSparseAndNeverReplacesAnExistingOne() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = directory.appending(path: "library.img")

		try BackingFile.create(at: url, size: 1 << 30)
		var status = stat()
		#expect(stat(url.path, &status) == 0)

		#expect(status.st_size == 1 << 30)
		#expect(status.st_blocks * 512 < 1 << 20)
		#expect(throws: DiskError.io(errno: EEXIST)) { try BackingFile.create(at: url, size: 1) }
		#expect(try OrderedDisk(backing: url).read(at: (1 << 30) - 4, count: 4) == [0, 0, 0, 0])
	}

	@Test func restoringReplacesTheDiskWithACloneOfThePristineCopy() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let pristine = directory.appending(path: "pristine.img")
		let library = directory.appending(path: "library.img")
		try Data(filled(1, 8_192)).write(to: pristine)
		try Data(filled(2, 100)).write(to: library)

		try BackingFile.restore(library, from: pristine)
		try OrderedDisk(backing: library).write([3], at: 0)

		#expect(try Data(contentsOf: library) == Data([3] + filled(1, 8_191)))
		#expect(try Data(contentsOf: pristine) == Data(filled(1, 8_192)))
	}
}
