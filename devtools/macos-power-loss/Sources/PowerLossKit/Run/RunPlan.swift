public struct PlannedRun: Codable, Equatable, Sendable {
	public let number: Int
	public let cutAfterMilliseconds: Int
	public let tearSeed: UInt64?

	public init(number: Int, cutAfterMilliseconds: Int, tearSeed: UInt64?) {
		self.number = number
		self.cutAfterMilliseconds = cutAfterMilliseconds
		self.tearSeed = tearSeed
	}
}

public enum RunPlan {
	public static let earlyCuts = 200 ... 6_000
	public static let lateCuts = 20_000 ... 60_000

	public static func cutWindow(forRun number: Int) -> ClosedRange<Int> {
		number.isMultiple(of: 2) ? lateCuts : earlyCuts
	}

	public static func make(seed: UInt64, count: Int, tearing: Bool = true) -> [PlannedRun] {
		var generator = SplitMix64(seed: seed)
		return (0 ..< max(count, 0)).map { index in
			let number = index + 1
			let window = cutWindow(forRun: number)
			let delay = window.lowerBound + Int(generator.next() % UInt64(window.count))
			let tearSeed = generator.next()
			return PlannedRun(number: number, cutAfterMilliseconds: delay, tearSeed: tearing ? tearSeed : nil)
		}
	}
}
