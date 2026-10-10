import Foundation

public enum AgentLog {
	public static let emptyTail = "(empty: the agent has written nothing since the setup script restarted it)"

	public static func line(_ message: String, at date: Date = .now) -> String {
		"power-loss-agent: \(date.formatted(.iso8601)) \(message)\n"
	}

	public static func listening(on port: UInt32, at date: Date = .now) -> String {
		line("listening on vsock port \(port)", at: date)
	}

	public static func shown(_ tail: [String]) -> [String] {
		tail.isEmpty ? [emptyTail] : tail
	}
}
