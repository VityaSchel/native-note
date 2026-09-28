public enum TypistControl: String, Codable, CaseIterable, Sendable {
	case earlyAck = "early-ack"

	public var typistMode: String {
		switch self {
		case .earlyAck: "acknowledge-before-saving"
		}
	}
}
