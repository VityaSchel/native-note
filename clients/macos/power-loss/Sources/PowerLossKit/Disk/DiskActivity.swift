public struct DiskActivity: Codable, Equatable, Sendable {
	public var reads = 0
	public var writes = 0
	public var forcedWrites = 0
	public var flushes = 0
	public var trims = 0
	public var writeZeroes = 0
	public var cache = 0
	public var rejected = 0
	public var unknown = 0

	public init(reads: Int = 0, writes: Int = 0, forcedWrites: Int = 0, flushes: Int = 0, trims: Int = 0, writeZeroes: Int = 0, cache: Int = 0, rejected: Int = 0, unknown: Int = 0) {
		self.reads = reads
		self.writes = writes
		self.forcedWrites = forcedWrites
		self.flushes = flushes
		self.trims = trims
		self.writeZeroes = writeZeroes
		self.cache = cache
		self.rejected = rejected
		self.unknown = unknown
	}

	private static var counters: [(name: String, value: WritableKeyPath<DiskActivity, Int>)] {
		[
			("reads", \.reads), ("writes", \.writes), ("forced writes", \.forcedWrites), ("flushes", \.flushes), ("trims", \.trims),
			("write-zeroes", \.writeZeroes), ("cache", \.cache), ("rejected", \.rejected), ("unknown", \.unknown),
		]
	}

	public func since(_ earlier: DiskActivity) -> DiskActivity {
		var difference = self
		for counter in Self.counters {
			difference[keyPath: counter.value] -= earlier[keyPath: counter.value]
		}
		return difference
	}

	public var summary: String {
		let counted = Self.counters.filter { self[keyPath: $0.value] != 0 }.map { "\($0.name) \(self[keyPath: $0.value])" }
		return counted.isEmpty ? "nothing" : counted.joined(separator: ", ")
	}
}
