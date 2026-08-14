import Foundation

nonisolated struct Note: Equatable, Identifiable, Sendable {
	var id: UUID
	var body: String
	var createdAt: Date
	var updatedAt: Date
	var deleted = false
	var dirty = false
	var v: UInt32 = 0
	var seq: Int64?

	var title: String {
		body.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
	}
}

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
