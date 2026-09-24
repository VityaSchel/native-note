import Foundation

nonisolated public struct Note: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var body: String
	public var createdAt: Date
	public var updatedAt: Date
	var deleted = false
	var dirty = false
	var v: UInt32 = 0
	var seq: Int64?

	public var title: String {
		body.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
	}
}
