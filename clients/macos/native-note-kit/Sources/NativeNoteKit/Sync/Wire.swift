import Foundation

nonisolated enum WireError: Error, Equatable {
	case truncated
	case trailingBytes
	case unknownDiscriminant
	case notCanonical
}

/// Reads the fixed big-endian layout of docs/PROTOCOL.md § Binary encoding, bounds-checking every field.
nonisolated struct WireReader {
	private let buffer: Data
	private var offset: Int

	init(_ buffer: Data) {
		self.buffer = buffer
		offset = buffer.startIndex
	}

	mutating func take(_ count: Int) throws(WireError) -> Data {
		guard count <= buffer.endIndex - offset else { throw .truncated }
		defer { offset += count }
		return Data(buffer[offset ..< offset + count])
	}

	mutating func u8() throws(WireError) -> UInt8 {
		try take(1).first ?? 0
	}

	mutating func u32() throws(WireError) -> UInt32 {
		try take(4).reduce(0) { $0 << 8 | UInt32($1) }
	}

	mutating func u64() throws(WireError) -> UInt64 {
		try take(8).reduce(0) { $0 << 8 | UInt64($1) }
	}

	mutating func i64() throws(WireError) -> Int64 {
		Int64(bitPattern: try u64())
	}

	mutating func uuid() throws(WireError) -> UUID {
		let bytes = try take(16)
		return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
	}

	mutating func bool() throws(WireError) -> Bool {
		switch try u8() {
		case 0: false
		case 1: true
		default: throw .notCanonical
		}
	}

	mutating func bytes() throws(WireError) -> Data {
		try take(Int(try u32()))
	}

	mutating func items<T>(_ item: (inout WireReader) throws(WireError) -> T) throws(WireError) -> [T] {
		let count = try u32()
		var items: [T] = []
		for _ in 0 ..< count {
			items.append(try item(&self))
		}
		return items
	}

	func finish() throws(WireError) {
		guard offset == buffer.endIndex else { throw .trailingBytes }
	}
}

nonisolated struct WireWriter {
	private(set) var data = Data()

	mutating func u8(_ value: UInt8) {
		data.append(value)
	}

	mutating func u32(_ value: UInt32) {
		withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
	}

	mutating func u64(_ value: UInt64) {
		withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
	}

	mutating func i64(_ value: Int64) {
		u64(UInt64(bitPattern: value))
	}

	mutating func fixed(_ value: Data) {
		data.append(value)
	}

	mutating func bytes(_ value: Data) {
		u32(UInt32(value.count))
		data.append(value)
	}
}
