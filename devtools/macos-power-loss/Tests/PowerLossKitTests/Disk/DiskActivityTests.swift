import Foundation
import Testing

@testable import PowerLossKit

struct DiskActivityTests {
	@Test func theDifferenceSubtractsEveryCounter() {
		let later = DiskActivity(reads: 9, writes: 8, forcedWrites: 7, flushes: 6, trims: 5, writeZeroes: 4, cache: 3, rejected: 2, unknown: 1)
		let earlier = DiskActivity(reads: 1, writes: 1, forcedWrites: 1, flushes: 1, trims: 1, writeZeroes: 1, cache: 1, rejected: 1, unknown: 1)

		#expect(later.since(earlier) == DiskActivity(reads: 8, writes: 7, forcedWrites: 6, flushes: 5, trims: 4, writeZeroes: 3, cache: 2, rejected: 1, unknown: 0))
	}

	@Test func theSummaryNamesOnlyTheCountersThatMoved() {
		#expect(DiskActivity().summary == "nothing")
		#expect(DiskActivity(writes: 3, flushes: 1, unknown: 2).summary == "writes 3, flushes 1, unknown 2")
		#expect(DiskActivity(forcedWrites: 1, writeZeroes: 2).summary == "forced writes 1, write-zeroes 2")
	}

	@Test func theActivityReadsBackFromJSON() throws {
		let activity = DiskActivity(reads: 1, writes: 2, forcedWrites: 3, flushes: 4, trims: 5, writeZeroes: 6, cache: 7, rejected: 8, unknown: 9)

		#expect(try JSONDecoder().decode(DiskActivity.self, from: JSONEncoder().encode(activity)) == activity)
	}
}
