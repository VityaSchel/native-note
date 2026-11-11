import Foundation

/// The end-to-end encrypted layout of docs/PROTOCOL.md § Content, timestamps in epoch milliseconds, zero-filled to whole blocks.
nonisolated enum Content: Equatable, Sendable {
	case note(id: UUID, createdAt: Int64, updatedAt: Int64, body: String)
	case tombstone(id: UUID, deletedAt: Int64)

	static let block = 4096
	private static let version: UInt8 = 0x01
	private static let noteKind: UInt8 = 0x01
	private static let tombstoneKind: UInt8 = 0x02

	var id: UUID {
		switch self {
		case let .note(id, _, _, _), let .tombstone(id, _): id
		}
	}

	func encoded() -> Data {
		var writer = WireWriter()
		writer.u8(Self.version)
		switch self {
		case let .note(id, createdAt, updatedAt, body):
			writer.u8(Self.noteKind)
			writer.fixed(id.bytes)
			writer.i64(createdAt)
			writer.i64(updatedAt)
			writer.bytes(Data(body.utf8))
		case let .tombstone(id, deletedAt):
			writer.u8(Self.tombstoneKind)
			writer.fixed(id.bytes)
			writer.i64(deletedAt)
		}
		var encoded = writer.data
		encoded.append(Data(count: (Self.block - encoded.count % Self.block) % Self.block))
		return encoded
	}

	static func decode(_ bytes: Data) throws(WireError) -> Content {
		var reader = WireReader(bytes)
		guard try reader.u8() == version else { throw .unknownDiscriminant }
		let content: Content
		switch try reader.u8() {
		case noteKind:
			let id = try reader.uuid()
			let createdAt = try reader.i64()
			let updatedAt = try reader.i64()
			guard let body = String(validating: try reader.bytes(), as: UTF8.self) else { throw .notCanonical }
			content = .note(id: id, createdAt: createdAt, updatedAt: updatedAt, body: body)
		case tombstoneKind:
			content = .tombstone(id: try reader.uuid(), deletedAt: try reader.i64())
		default:
			throw .unknownDiscriminant
		}
		try reader.finishFilled(toMultipleOf: block)
		return content
	}
}
