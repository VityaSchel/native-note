public enum ProbeMarker: Equatable, Sendable {
	case before(step: Int, call: String)
	case after(step: Int, call: String, result: Int, errno: Int32, microseconds: UInt64)

	public init?(line: String) {
		if let match = line.wholeMatch(of: #/probe: step (\d+) before: (.+)/#), let step = Int(match.1) {
			self = .before(step: step, call: String(match.2))
		} else if let match = line.wholeMatch(of: #/probe: step (\d+) after: (.+) -> result (-?\d+), errno (\d+), (\d+) us/#),
			let step = Int(match.1), let result = Int(match.3), let error = Int32(match.4), let microseconds = UInt64(match.5)
		{
			self = .after(step: step, call: String(match.2), result: result, errno: error, microseconds: microseconds)
		} else {
			return nil
		}
	}

	public var line: String {
		switch self {
		case .before(let step, let call):
			"probe: step \(step) before: \(call)"
		case .after(let step, let call, let result, let errno, let microseconds):
			"probe: step \(step) after: \(call) -> result \(result), errno \(errno), \(microseconds) us"
		}
	}

	public var step: Int {
		switch self {
		case .before(let step, _), .after(let step, _, _, _, _): step
		}
	}
}

public struct ProbeStep: Equatable, Sendable {
	public let number: Int
	public let call: String
	public let before: DiskActivity
	public var after: DiskActivity?
	public var result: Int?
	public var errno: Int32?
	public var microseconds: UInt64?

	public var effect: DiskActivity? {
		after?.since(before)
	}
}

public struct ProbeTimeline: Equatable, Sendable {
	public private(set) var steps: [ProbeStep] = []
	public private(set) var strays: [ProbeMarker] = []

	public init() {}

	public mutating func mark(_ marker: ProbeMarker, activity: DiskActivity) {
		switch marker {
		case .before(let step, let call):
			steps.append(ProbeStep(number: step, call: call, before: activity))
		case .after(let step, _, let result, let errno, let microseconds):
			guard let index = steps.indices.last, steps[index].number == step, steps[index].after == nil else {
				strays.append(marker)
				return
			}
			steps[index].after = activity
			steps[index].result = result
			steps[index].errno = errno
			steps[index].microseconds = microseconds
		}
	}

	public var report: [String] {
		var lines: [String] = []
		for (index, step) in steps.enumerated() {
			if index > 0, let previous = steps[index - 1].after {
				lines.append("  between steps: \(step.before.since(previous).summary)")
			}
			guard let effect = step.effect, let result = step.result, let errno = step.errno, let microseconds = step.microseconds else {
				lines.append("step \(step.number) \(step.call): never finished")
				continue
			}
			lines.append("step \(step.number) \(step.call): result \(result), errno \(errno), \(microseconds) us; the server saw \(effect.summary)")
		}
		lines += strays.map { "unmatched marker: \($0.line)" }
		return lines
	}
}
