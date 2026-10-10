public enum ProbeTarget: String, CaseIterable, Sendable {
	case library
	case system
}

public enum AgentRequest: Equatable, Sendable {
	case hello
	case prepare(password: String)
	case type(password: String, control: TypistControl? = nil)
	case verify(password: String)
	case install(byteCount: Int)
	case diagnose
	case probe(ProbeTarget)
	case shutdown

	public static let port: UInt32 = 7040
	static let controlPrefix = "type-"

	public init?(line: String) {
		let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
		let word = parts.first.map(String.init) ?? ""
		let argument = parts.count == 2 && !parts[1].isEmpty ? String(parts[1]) : nil
		switch (word, argument) {
		case ("hello", nil): self = .hello
		case ("shutdown", nil): self = .shutdown
		case ("diagnose", nil): self = .diagnose
		case ("probe", let target?):
			guard let target = ProbeTarget(rawValue: target) else { return nil }
			self = .probe(target)
		case ("prepare", let password?): self = .prepare(password: password)
		case ("type", let password?): self = .type(password: password)
		case (let typing, let password?) where typing.hasPrefix(Self.controlPrefix):
			guard let control = TypistControl(rawValue: String(typing.dropFirst(Self.controlPrefix.count))) else { return nil }
			self = .type(password: password, control: control)
		case ("verify", let password?): self = .verify(password: password)
		case ("install", let count?):
			guard let byteCount = Int(count), byteCount > 0 else { return nil }
			self = .install(byteCount: byteCount)
		default: return nil
		}
	}

	public var line: String {
		switch self {
		case .hello: "hello"
		case .shutdown: "shutdown"
		case .prepare(let password): "prepare \(password)"
		case .type(let password, nil): "type \(password)"
		case .type(let password, let control?): "\(Self.controlPrefix)\(control.rawValue) \(password)"
		case .verify(let password): "verify \(password)"
		case .install(let byteCount): "install \(byteCount)"
		case .diagnose: "diagnose"
		case .probe(let target): "probe \(target.rawValue)"
		}
	}

	public var typistArguments: (mode: String, password: String)? {
		switch self {
		case .hello, .shutdown, .install, .diagnose, .probe: nil
		case .prepare(let password): ("prepare", password)
		case .type(let password, let control): (control?.typistMode ?? "acknowledge", password)
		case .verify(let password): ("verify", password)
		}
	}
}

public enum AgentReply: Equatable, Sendable {
	case ready
	case done
	case exit(Int32)
	case failure(String)
	case output(String)

	public init(line: String) {
		if line == "ready" {
			self = .ready
		} else if line == "ok" {
			self = .done
		} else if line.hasPrefix("exit "), let status = Int32(line.dropFirst(5)) {
			self = .exit(status)
		} else if line.hasPrefix("error ") {
			self = .failure(String(line.dropFirst(6)))
		} else {
			self = .output(line)
		}
	}

	public var line: String {
		switch self {
		case .ready: "ready"
		case .done: "ok"
		case .exit(let status): "exit \(status)"
		case .failure(let message): "error \(message.split(whereSeparator: \.isNewline).joined(separator: " "))"
		case .output(let line): line
		}
	}
}
