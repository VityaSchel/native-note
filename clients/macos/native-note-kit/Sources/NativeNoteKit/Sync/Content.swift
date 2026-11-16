import Foundation

nonisolated enum Content: Equatable, Sendable {
	case note(id: UUID, createdAt: Int64, updatedAt: Int64, body: String, ext: Data = Data())
	case tombstone(id: UUID, deletedAt: Int64)

	struct Prefix: Equatable {
		let version: UInt8
		let kind: UInt8
		let id: UUID

		var isKnown: Bool {
			version == Content.version && [Content.noteKind, Content.tombstoneKind].contains(kind)
		}
	}

	static let block = 4096
	private static let version: UInt8 = 0x01
	private static let noteKind: UInt8 = 0x01
	private static let tombstoneKind: UInt8 = 0x02

	var id: UUID {
		switch self {
		case let .note(id, _, _, _, _), let .tombstone(id, _): id
		}
	}

	func encoded() -> Data {
		var writer = WireWriter()
		writer.u8(Self.version)
		switch self {
		case let .note(id, createdAt, updatedAt, body, ext):
			writer.u8(Self.noteKind)
			writer.fixed(id.bytes)
			writer.i64(createdAt)
			writer.i64(updatedAt)
			writer.bytes(Data(body.utf8))
			writer.bytes(ext)
		case let .tombstone(id, deletedAt):
			writer.u8(Self.tombstoneKind)
			writer.fixed(id.bytes)
			writer.i64(deletedAt)
		}
		var encoded = writer.data
		encoded.append(Data(count: (Self.block - encoded.count % Self.block) % Self.block))
		return encoded
	}

	static func prefix(of bytes: Data) throws(WireError) -> Prefix {
		var reader = WireReader(bytes)
		return Prefix(version: try reader.u8(), kind: try reader.u8(), id: try reader.uuid())
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
			content = .note(id: id, createdAt: createdAt, updatedAt: updatedAt, body: body, ext: try reader.bytes())
		case tombstoneKind:
			content = .tombstone(id: try reader.uuid(), deletedAt: try reader.i64())
		default:
			throw .unknownDiscriminant
		}
		try reader.finishFilled(toMultipleOf: block)
		return content
	}
}
