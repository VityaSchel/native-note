import Darwin

struct SocketChannel {
	enum Failure: Error, Equatable {
		case closed
		case failed(errno: Int32)
	}

	private static let discardChunk = 1 << 20

	let descriptor: Int32

	func receive(_ count: Int) throws -> [UInt8] {
		var bytes = [UInt8](repeating: 0, count: count)
		var done = 0
		while done < count {
			let result = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress! + done, count - done) }
			if result > 0 {
				done += result
			} else if result == 0 {
				throw Failure.closed
			} else if errno != EINTR {
				throw Failure.failed(errno: errno)
			}
		}
		return bytes
	}

	func receive<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
		var reader = ByteReader(try receive(MemoryLayout<T>.size))
		return try reader.integer()
	}

	func discard(_ count: Int) throws {
		var remaining = count
		while remaining > 0 {
			let chunk = min(remaining, Self.discardChunk)
			_ = try receive(chunk)
			remaining -= chunk
		}
	}

	func send(_ bytes: [UInt8]) throws {
		var done = 0
		while done < bytes.count {
			let result = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress! + done, bytes.count - done) }
			if result > 0 {
				done += result
			} else if result < 0, errno == EINTR {
				continue
			} else {
				throw Failure.failed(errno: result < 0 ? errno : EIO)
			}
		}
	}
}
