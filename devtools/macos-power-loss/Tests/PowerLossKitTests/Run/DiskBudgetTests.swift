import Darwin
import Foundation
import Testing

@testable import PowerLossKit

struct DiskBudgetTests {
	@Test func anAllocationMustLeaveFortyGibibytesFree() throws {
		#expect(DiskBudget.allows(allocating: 10 << 30, free: 50 << 30))
		#expect(!DiskBudget.allows(allocating: 10 << 30 + 1, free: 50 << 30))
		#expect(try DiskBudget.freeBytes(at: FileManager.default.temporaryDirectory) > 0)
	}

	@Test func theHarnessStopsBelowFortyGibibytesFreeOrAboveFortyFiveGigabytesUsed() throws {
		try DiskBudget.check(free: 40 << 30, allocated: 45_000_000_000)
		#expect(throws: DiskBudget.Exceeded(description: "only 39 GiB are free, and the harness keeps 40 GiB free")) {
			try DiskBudget.check(free: 40 << 30 - 1, allocated: 0)
		}
		#expect(throws: DiskBudget.Exceeded(description: "the VM files take 45 GB, over the 45 GB the harness allows")) {
			try DiskBudget.check(free: 100 << 30, allocated: 45_000_000_001)
		}
	}

	@Test func onlyAllocatedBlocksOutsideTheRestoreImageCount() throws {
		let directory = try temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(at: directory.appending(path: "vm"), withIntermediateDirectories: true)
		try Data(filled(1, 1 << 20)).write(to: directory.appending(path: "vm/written.img"))
		try BackingFile.create(at: directory.appending(path: "vm/sparse.img"), size: 1 << 30)
		try Data(filled(2, 1 << 20)).write(to: directory.appending(path: "restore.ipsw"))

		let allocated = try DiskBudget.allocatedBytes(in: directory)

		#expect((1 << 20 ... (1 << 20) + (64 << 10)).contains(allocated))
	}
}
