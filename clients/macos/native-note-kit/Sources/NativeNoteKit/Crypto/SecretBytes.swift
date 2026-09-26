import Foundation

nonisolated enum SecretBytes {
	static func wipe(_ buffer: UnsafeMutableRawBufferPointer) {
		guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
		_ = memset_s(base, buffer.count, 0, buffer.count)
	}

	static func wiping<T>(_ buffer: UnsafeMutableRawBufferPointer, _ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
		defer { wipe(buffer) }
		return try body(buffer)
	}

	static func withScratch<T>(byteCount: Int, _ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
		try withUnsafeTemporaryAllocation(byteCount: byteCount, alignment: 16) { try wiping($0, body) }
	}

	static func withUTF8<T>(of string: String, _ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
		try withScratch(byteCount: string.utf8.count) { buffer in
			buffer.copyBytes(from: string.utf8)
			return try body(UnsafeRawBufferPointer(buffer))
		}
	}
}
