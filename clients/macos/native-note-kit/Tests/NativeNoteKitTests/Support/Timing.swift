import Foundation

struct Timings {
	private(set) var milliseconds: [Double] = []

	init() {}

	init(merging rounds: [Timings]) {
		milliseconds = rounds.flatMap(\.milliseconds)
	}

	mutating func measure(_ work: () async throws -> Void) async rethrows {
		let start = DispatchTime.now().uptimeNanoseconds
		try await work()
		milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
	}

	func percentile(_ fraction: Double) -> Double {
		let sorted = milliseconds.sorted()
		return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
	}
}
