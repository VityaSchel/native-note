public struct NBDExport: Sendable {
	public var name: String
	public var minimumBlockSize: UInt32
	public var preferredBlockSize: UInt32
	public var maximumPayload: UInt32

	public init(name: String = "library", minimumBlockSize: UInt32 = 512, preferredBlockSize: UInt32 = 4096, maximumPayload: UInt32 = 32 << 20) {
		self.name = name
		self.minimumBlockSize = minimumBlockSize
		self.preferredBlockSize = preferredBlockSize
		self.maximumPayload = maximumPayload
	}
}

enum NBD {
	enum Magic {
		static let greeting: UInt64 = 0x4E42_444D_4147_4943
		static let option: UInt64 = 0x4948_4156_454F_5054
		static let optionReply: UInt64 = 0x0003_E889_0455_65A9
		static let request: UInt32 = 0x2560_9513
		static let simpleReply: UInt32 = 0x6744_6698
	}

	enum HandshakeFlag {
		static let fixedNewstyle: UInt16 = 1 << 0
		static let noZeroes: UInt16 = 1 << 1
	}

	enum ClientFlag {
		static let fixedNewstyle: UInt32 = 1 << 0
		static let noZeroes: UInt32 = 1 << 1
	}

	enum TransmissionFlag {
		static let hasFlags: UInt16 = 1 << 0
		static let sendFlush: UInt16 = 1 << 2
		static let sendForceUnitAccess: UInt16 = 1 << 3
		static let sendTrim: UInt16 = 1 << 5
		static let sendWriteZeroes: UInt16 = 1 << 6
	}

	enum Option: UInt32 {
		case exportName = 1
		case abort = 2
		case list = 3
		case startTLS = 5
		case info = 6
		case go = 7
	}

	enum OptionReply: UInt32 {
		case acknowledge = 1
		case server = 2
		case info = 3
		case unsupported = 0x8000_0001
		case policy = 0x8000_0002
		case invalid = 0x8000_0003
		case unknown = 0x8000_0006
		case shutdown = 0x8000_0007
	}

	enum Info: UInt16 {
		case export = 0
		case blockSize = 3
	}

	enum Command: UInt16 {
		case read = 0
		case write = 1
		case disconnect = 2
		case flush = 3
		case trim = 4
		case cache = 5
		case writeZeroes = 6

		var name: String {
			switch self {
			case .read: "READ"
			case .write: "WRITE"
			case .disconnect: "DISC"
			case .flush: "FLUSH"
			case .trim: "TRIM"
			case .cache: "CACHE"
			case .writeZeroes: "WRITE_ZEROES"
			}
		}
	}

	enum CommandFlag {
		static let forceUnitAccess: UInt16 = 1 << 0
		static let noHole: UInt16 = 1 << 1

		private static let names = ["FUA", "NO_HOLE", "DF", "REQ_ONE", "FAST_ZERO", "PAYLOAD_LEN"]

		static func describe(_ flags: UInt16) -> String {
			let digits = String(flags, radix: 16)
			let hex = "0x" + String(repeating: "0", count: 4 - digits.count) + digits
			let set = (0 ..< 16).filter { flags & 1 << $0 != 0 }.map { $0 < names.count ? names[$0] : "bit \($0)" }
			return set.isEmpty ? hex : "\(hex) (\(set.joined(separator: "|")))"
		}
	}

	enum Failure: UInt32 {
		case none = 0
		case io = 5
		case invalid = 22
		case noSpace = 28

		var name: String {
			switch self {
			case .none: "success"
			case .io: "EIO"
			case .invalid: "EINVAL"
			case .noSpace: "ENOSPC"
			}
		}
	}

	static let transmissionFlags = TransmissionFlag.hasFlags | TransmissionFlag.sendFlush | TransmissionFlag.sendForceUnitAccess
		| TransmissionFlag.sendTrim | TransmissionFlag.sendWriteZeroes
	static let requestHeaderSize = 28
	static let maximumOptionLength = 1 << 20
	static let exportNamePadding = 124
}

struct ByteWriter {
	private(set) var bytes: [UInt8] = []

	mutating func append<T: FixedWidthInteger>(_ value: T) {
		withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
	}

	mutating func append(_ other: [UInt8]) {
		bytes.append(contentsOf: other)
	}
}

struct ByteReader {
	struct Truncated: Error {}

	private let bytes: [UInt8]
	private var position = 0

	init(_ bytes: [UInt8]) {
		self.bytes = bytes
	}

	var remaining: Int {
		bytes.count - position
	}

	mutating func integer<T: FixedWidthInteger>(_: T.Type = T.self) throws -> T {
		let field = try take(MemoryLayout<T>.size)
		return field.reduce(T.zero) { $0 << 8 | T($1) }
	}

	mutating func take(_ count: Int) throws -> [UInt8] {
		guard count >= 0, count <= remaining else { throw Truncated() }
		defer { position += count }
		return Array(bytes[position ..< position + count])
	}
}
