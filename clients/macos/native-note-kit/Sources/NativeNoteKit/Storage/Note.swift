import Foundation

nonisolated public struct Note: Equatable, Identifiable, Sendable {
	public internal(set) var id: UUID
	public internal(set) var body: String
	var createdAt: Date
	public internal(set) var updatedAt: Date
	var deleted = false
	var dirty = false
	var v: UInt32 = 0
	var seq: Int64?

	public var title: String {
		body.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
	}
}
