public struct Acknowledgement: Codable, Equatable, Sendable {
	public let sequence: Int
	public let length: Int
	public let digest: String

	public init(sequence: Int, length: Int, digest: String) {
		self.sequence = sequence
		self.length = length
		self.digest = digest
	}
}

public enum TypistLine: Equatable, Sendable {
	case start(length: Int)
	case keystroke(length: Int, uptimeNanoseconds: UInt64)
	case acknowledged(Acknowledgement)
	case prepared(notes: Int)
	case unsaved(String)
	case other(String)

	public init(_ line: String) {
		let fields = line.split(separator: " ", omittingEmptySubsequences: false)
		switch fields.first {
		case "start" where fields.count == 2:
			self = Int(fields[1]).map { .start(length: $0) } ?? .other(line)
		case "prepared" where fields.count == 2:
			self = Int(fields[1]).map { .prepared(notes: $0) } ?? .other(line)
		case "unsaved:":
			self = .unsaved(fields.dropFirst().joined(separator: " "))
		case "ack" where fields.count == 4:
			guard let sequence = Int(fields[1]), let length = Int(fields[2]), fields[3].count == 64 else {
				self = .other(line)
				return
			}
			self = .acknowledged(Acknowledgement(sequence: sequence, length: length, digest: String(fields[3])))
		default:
			guard fields.count == 2, let length = Int(fields[0]), let uptime = UInt64(fields[1]) else {
				self = .other(line)
				return
			}
			self = .keystroke(length: length, uptimeNanoseconds: uptime)
		}
	}
}

public struct TypingLog: Equatable, Sendable {
	public private(set) var start: Int?
	public private(set) var typed = 0
	public private(set) var acknowledgements: [Acknowledgement] = []
	public private(set) var unsaved: [String] = []
	public private(set) var unexpected: [String] = []
	public private(set) var longestPauseBetweenKeystrokes = Duration.zero
	private var typedAt: [Int: UInt64] = [:]
	private var firstKeystroke: UInt64?
	private var lastKeystroke: UInt64?

	public init(_ lines: some Sequence<String>) {
		for line in lines {
			switch TypistLine(line) {
			case .start(let length):
				start = length
				typed = max(typed, length)
			case .keystroke(let length, let uptime):
				typed = max(typed, length)
				typedAt[length] = typedAt[length] ?? uptime
				if let lastKeystroke {
					longestPauseBetweenKeystrokes = max(longestPauseBetweenKeystrokes, Self.elapsed(from: lastKeystroke, to: uptime))
				}
				firstKeystroke = firstKeystroke ?? uptime
				lastKeystroke = uptime
			case .acknowledged(let acknowledgement):
				acknowledgements.append(acknowledgement)
				typed = max(typed, acknowledgement.length)
			case .prepared:
				break
			case .unsaved(let failure):
				unsaved.append(failure)
			case .other(let line):
				unexpected.append(line)
			}
		}
	}

	public var acknowledged: Int {
		acknowledgements.map(\.length).max() ?? start ?? 0
	}

	public var typingSinceLastAcknowledgement: Duration {
		let acknowledgedAt = acknowledgements.isEmpty ? firstKeystroke : typedAt[acknowledged]
		guard let acknowledgedAt, let lastKeystroke else { return .zero }
		return Self.elapsed(from: acknowledgedAt, to: lastKeystroke)
	}

	private static func elapsed(from earlier: UInt64, to later: UInt64) -> Duration {
		later > earlier ? .nanoseconds(Int64(clamping: later - earlier)) : .zero
	}
}
