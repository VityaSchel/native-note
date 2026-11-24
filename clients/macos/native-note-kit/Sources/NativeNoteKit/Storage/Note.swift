import Foundation

nonisolated public struct Note: Equatable, Identifiable, Sendable {
	public internal(set) var id: UUID
	public internal(set) var body: String
	var createdAt: Int64
	var updatedAt: Int64
	var deleted = false
	var dirty = false
	public internal(set) var v: UInt32 = 0
	var ext = Data()

	public var updated: Date {
		Date(epochMilliseconds: updatedAt)
	}

	func unsyncedCopy(id: UUID = UUID()) -> Note {
		Note(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, dirty: true, ext: ext)
	}

	public var title: String {
		body.prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
	}
}
