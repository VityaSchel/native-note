nonisolated enum Hex {
	static func string(_ bytes: some Sequence<UInt8>) -> String {
		String(decoding: bytes.flatMap { [digit($0 >> 4), digit($0 & 0x0f)] }, as: UTF8.self)
	}

	static func digit(_ nibble: UInt8) -> UInt8 {
		nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10
	}

	static func nibble(_ digit: UInt8) -> UInt8? {
		switch digit {
		case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
		case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
		default: nil
		}
	}
}
