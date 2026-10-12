import Foundation

nonisolated public struct Note: Equatable, Identifiable, Sendable {
	public internal(set) var id: UUID
	public internal(set) var body: String
	var createdAt: Int64
	var updatedAt: Int64
	var deleted = false
	var dirty = false
	var v: UInt32 = 0
	var seq: Int64?

	public var updated: Date {
		Date(epochMilliseconds: updatedAt)
	}

	public var title: String {
		body.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
	}
}
