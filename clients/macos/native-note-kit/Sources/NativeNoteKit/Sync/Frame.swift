import Foundation

/// A note write as it travels, per docs/PROTOCOL.md § Action `sync`.
nonisolated struct Write: Equatable, Sendable {
	let blindedId: Data
	let v: UInt32
	let writeId: Data
	let payload: Data

	fileprivate static let headerLength = 16 + 4 + 16 + 4

	var encodedLength: Int {
		Self.headerLength + payload.count
	}

	fileprivate func encode(into writer: inout WireWriter) {
		writer.fixed(blindedId)
		writer.u32(v)
		writer.fixed(writeId)
		writer.bytes(payload)
	}

	fileprivate static func decode(from reader: inout WireReader) throws(WireError) -> Write {
		Write(blindedId: try reader.take(16), v: try reader.u32(), writeId: try reader.take(16), payload: try reader.bytes())
	}
}

nonisolated enum Status: UInt8, Sendable {
	case accepted = 0x01
	case conflict = 0x02
	case tooLarge = 0x03
}

nonisolated struct WriteResult: Equatable, Sendable {
	let status: Status
	let v: UInt32
	let seq: UInt64
}

nonisolated enum Request: Equatable, Sendable {
	case sync(since: UInt64, writes: [Write])
	case get
	case put(v: UInt32, blob: Data)

	static let syncHeaderLength = 1 + 8 + 4

	func encoded() -> Data {
		var writer = WireWriter()
		switch self {
		case let .sync(since, writes):
			writer.u8(Action.sync)
			writer.u64(since)
			writer.u32(UInt32(writes.count))
			for write in writes { write.encode(into: &writer) }
		case .get:
			writer.u8(Action.get)
		case let .put(v, blob):
			writer.u8(Action.put)
			writer.u32(v)
			writer.bytes(blob)
		}
		return writer.data
	}
}

nonisolated enum Response: Equatable, Sendable {
	case sync(results: [WriteResult], changes: [Write], nextSeq: UInt64, more: Bool)
	case get(v: UInt32, blob: Data)
	case put(status: Status, v: UInt32)
	case error

	static func decode(_ bytes: Data) throws(WireError) -> Response {
		var reader = WireReader(bytes)
		let response: Response
		switch try reader.u8() {
		case Action.sync:
			let results = try reader.items { (reader: inout WireReader) throws(WireError) in try Self.result(from: &reader) }
			let changes = try reader.items { (reader: inout WireReader) throws(WireError) in try Write.decode(from: &reader) }
			response = .sync(results: results, changes: changes, nextSeq: try reader.u64(), more: try reader.bool())
		case Action.get:
			response = .get(v: try reader.u32(), blob: try reader.bytes())
		case Action.put:
			let status = try Self.status(from: &reader)
			guard status != .tooLarge else { throw .unknownDiscriminant }
			response = .put(status: status, v: try reader.u32())
		case Action.error:
			response = .error
		default:
			throw .unknownDiscriminant
		}
		try reader.finish()
		return response
	}

	private static func status(from reader: inout WireReader) throws(WireError) -> Status {
		guard let status = Status(rawValue: try reader.u8()) else { throw .unknownDiscriminant }
		return status
	}

	private static func result(from reader: inout WireReader) throws(WireError) -> WriteResult {
		let result = WriteResult(status: try status(from: &reader), v: try reader.u32(), seq: try reader.u64())
		guard result.status == .accepted || result.seq == 0 else { throw .notCanonical }
		return result
	}
}

private nonisolated enum Action {
	static let sync: UInt8 = 0x01
	static let get: UInt8 = 0x02
	static let put: UInt8 = 0x03
	static let error: UInt8 = 0xff
}
