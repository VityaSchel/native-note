import Foundation

/// `len_be32 ‖ inner ‖ zero fill` to the smallest bucket that holds it, per docs/PROTOCOL.md § Padding.
nonisolated enum Padding {
	static let bodyMax = 2 << 20
	static let innerMax = bodyMax - lengthPrefix
	private static let lengthPrefix = 4
	private static let smallest = 256

	private static func bucket(holding length: Int) -> Int? {
		var bucket = smallest
		while bucket < length {
			bucket *= 2
		}
		return bucket <= bodyMax ? bucket : nil
	}

	static func pad(_ inner: Data) -> Data? {
		guard let bucket = bucket(holding: lengthPrefix + inner.count) else { return nil }
		var writer = WireWriter()
		writer.bytes(inner)
		var padded = writer.data
		padded.append(Data(count: bucket - padded.count))
		return padded
	}

	static func unpad(_ padded: Data) -> Data? {
		var reader = WireReader(padded)
		guard let inner = try? reader.bytes(),
			bucket(holding: lengthPrefix + inner.count) == padded.count,
			padded.dropFirst(lengthPrefix + inner.count).allSatisfy({ $0 == 0 })
		else { return nil }
		return inner
	}
}
