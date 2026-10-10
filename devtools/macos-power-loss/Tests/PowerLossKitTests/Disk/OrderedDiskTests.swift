import Foundation
import Testing

@testable import PowerLossKit

struct OrderedDiskTests {
	private static let sector = 4_096

	@Test func aWriteIsDurableTheMomentItReturns() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()

		try scratch.disk.write(filled(7, 100), at: 1_000)
		model.write(filled(7, 100), at: 1_000)

		#expect(try scratch.durable == model.bytes)
		#expect(try scratch.disk.read(at: 900, count: 300) == Array(model.bytes[900 ..< 1_200]))
	}

	@Test func anAcknowledgedWriteSurvivesACut() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()

		try scratch.disk.write(filled(1, 8_192), at: 4_096)
		model.write(filled(1, 8_192), at: 4_096)
		scratch.disk.cutPower(tearingWith: nil)

		#expect(try scratch.durable == model.bytes)
		scratch.disk.restorePower()
		#expect(try scratch.disk.read(at: 0, count: ScratchDisk.size) == model.bytes)
	}

	@Test func aWriteAfterACutThatTearsNothingIsNeverApplied() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }

		scratch.disk.cutPower(tearingWith: nil)

		#expect(throws: DiskError.poweredOff) { try scratch.disk.write(filled(2, 4_096), at: 0) }
		#expect(throws: DiskError.poweredOff) { try scratch.disk.zero(at: 8_192, count: 4_096) }
		#expect(scratch.disk.tornWrite == nil)
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test(arguments: 0 ..< 64 as Range<UInt64>)
	func aTornWriteKeepsExactlyASectorAlignedPrefixOfItselfAndNothingElse(seed: UInt64) throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()
		let (offset, length) = (1_000, 5 * Self.sector + 300)
		try scratch.disk.write(filled(1, 2_000), at: 40_000)
		model.write(filled(1, 2_000), at: 40_000)

		scratch.disk.cutPower(tearingWith: seed)
		#expect(throws: DiskError.poweredOff) { try scratch.disk.write(filled(2, length), at: offset) }
		#expect(throws: DiskError.poweredOff) { try scratch.disk.write(filled(3, 1_000), at: 50_000) }

		let torn = try #require(scratch.disk.tornWrite)
		#expect(torn.offset == offset)
		#expect(torn.length == length)
		#expect(!torn.zeroes)
		#expect(torn.kept == 0 || torn.kept == length || (offset + torn.kept) % Self.sector == 0)
		model.write(filled(2, torn.kept), at: offset)
		#expect(try scratch.durable == model.bytes)
	}

	@Test func aZeroingChangeTearsLikeAWrite() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()
		let seed = try #require((0 ..< 64 as Range<UInt64>).first { seed in
			let kept = OrderedDisk.tearPoint(offset: 0, length: 4 * Self.sector, sectorSize: Self.sector, seed: seed)
			return 0 < kept && kept < 4 * Self.sector
		})

		scratch.disk.cutPower(tearingWith: seed)
		#expect(throws: DiskError.poweredOff) { try scratch.disk.zero(at: 0, count: 4 * Self.sector) }

		let torn = try #require(scratch.disk.tornWrite)
		#expect(torn.zeroes)
		model.write(filled(0, torn.kept), at: 0)
		#expect(try scratch.durable == model.bytes)
	}

	@Test func aTornWriteRecordsHowLongAfterTheCutItArrived() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }

		scratch.disk.cutPower(tearingWith: 3)
		usleep(60_000)
		_ = try? scratch.disk.write(filled(2, 4_096), at: 0)

		let torn = try #require(scratch.disk.tornWrite)
		#expect((60 ..< 5_000).contains(torn.millisecondsAfterCut))
	}

	@Test func theTearPointReplaysFromTheSeed() {
		for seed in 0 ..< 32 as Range<UInt64> {
			let first = OrderedDisk.tearPoint(offset: 1_000, length: 9 * Self.sector, sectorSize: Self.sector, seed: seed)
			#expect(OrderedDisk.tearPoint(offset: 1_000, length: 9 * Self.sector, sectorSize: Self.sector, seed: seed) == first)
		}
	}

	@Test func everyTearPointIsReachableAndNoOtherIs() {
		let (offset, length) = (1_000, 3 * Self.sector)
		let reached = Set((0 ..< 512 as Range<UInt64>).map { OrderedDisk.tearPoint(offset: offset, length: length, sectorSize: Self.sector, seed: $0) })

		#expect(reached == [0, 4_096 - 1_000, 8_192 - 1_000, 12_288 - 1_000, length])
	}

	@Test(arguments: [(0, 4_096), (512, 512), (8_192, 1), (100, 0)])
	func aWriteWithinOneSectorIsEitherLostOrKeptWhole(offset: Int, length: Int) {
		let reached = Set((0 ..< 64 as Range<UInt64>).map { OrderedDisk.tearPoint(offset: offset, length: length, sectorSize: Self.sector, seed: $0) })

		#expect(reached == [0, length])
	}

	@Test func onlyTheFirstChangeAfterACutIsTornEvenIfPowerIsCutAgain() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }

		scratch.disk.cutPower(tearingWith: 1)
		_ = try? scratch.disk.write(filled(2, 4_096), at: 0)
		let torn = scratch.disk.tornWrite
		scratch.disk.cutPower(tearingWith: 2)

		#expect(throws: DiskError.poweredOff) { try scratch.disk.write(filled(3, 4_096), at: 8_192) }
		#expect(scratch.disk.tornWrite == torn)
		#expect(try scratch.durable[8_192 ..< 12_288] == DiskModel().bytes[8_192 ..< 12_288])
	}

	@Test func aCutRefusesReadsUntilPowerReturns() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }

		scratch.disk.cutPower(tearingWith: 5)

		#expect(!scratch.disk.isPoweredOn)
		#expect(throws: DiskError.poweredOff) { try scratch.disk.read(at: 0, count: 1) }
		scratch.disk.restorePower()
		try scratch.disk.write([1], at: 0)
		#expect(scratch.disk.isPoweredOn)
		#expect(try scratch.disk.read(at: 0, count: 1) == [1])
	}

	@Test func overlappingAndUnalignedWritesLayerInOrder() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()

		for (value, offset, count) in [(1, 100, 200), (2, 200, 4_800), (3, 4_090, 10), (4, 0, 1)] as [(UInt8, Int, Int)] {
			try scratch.disk.write(filled(value, count), at: offset)
			model.write(filled(value, count), at: offset)
		}

		#expect(try scratch.disk.read(at: 0, count: 6_000) == Array(model.bytes[0 ..< 6_000]))
		#expect(try scratch.durable == model.bytes)
	}

	@Test func zeroedRangesReadAsZeros() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		var model = DiskModel()

		try scratch.disk.zero(at: 1_000, count: 12_000)
		model.write(filled(0, 12_000), at: 1_000)

		#expect(try scratch.disk.read(at: 0, count: ScratchDisk.size) == model.bytes)
		#expect(try scratch.durable == model.bytes)
	}

	@Test func requestsOutsideTheDiskAreRefused() throws {
		let scratch = try ScratchDisk()
		defer { scratch.remove() }
		let size = ScratchDisk.size

		#expect(scratch.disk.size == size)
		#expect(throws: DiskError.outOfBounds) { try scratch.disk.read(at: size - 10, count: 11) }
		#expect(throws: DiskError.outOfBounds) { try scratch.disk.write([1, 2], at: size - 1) }
		#expect(throws: DiskError.outOfBounds) { try scratch.disk.zero(at: -1, count: 1) }
		#expect(try scratch.durable == DiskModel().bytes)
	}

	@Test func aCutReportSurvivesAJSONRoundTrip() throws {
		let report = CutReport(torn: TornWrite(offset: 4_096, length: 16_384, kept: 8_192), dropped: DiskActivity(reads: 1, writes: 3, flushes: 1))

		let decoded = try JSONDecoder().decode(CutReport.self, from: JSONEncoder().encode(report))

		#expect(decoded == report)
	}
}
