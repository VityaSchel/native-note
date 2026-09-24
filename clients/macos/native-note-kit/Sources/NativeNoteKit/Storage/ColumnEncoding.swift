import Foundation

nonisolated extension UUID {
	var bytes: Data {
		withUnsafeBytes(of: uuid) { Data($0) }
	}

	init?(bytes: Data) {
		guard bytes.count == 16 else { return nil }
		self = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
	}
}

nonisolated extension Date {
	var epochMilliseconds: Int64 {
		Int64((timeIntervalSince1970 * 1000).rounded())
	}

	init(epochMilliseconds: Int64) {
		self.init(timeIntervalSince1970: Double(epochMilliseconds) / 1000)
	}
}
