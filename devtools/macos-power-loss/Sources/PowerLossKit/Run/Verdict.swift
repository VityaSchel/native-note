public struct Verdict: Codable, Equatable, Sendable {
	public let passed: Bool
	public let problems: [String]
	public let lostCharacters: Int

	public init(problems: [String], lostCharacters: Int = 0) {
		self.problems = problems
		self.lostCharacters = lostCharacters
		passed = problems.isEmpty
	}

	public static let longestTypingWithoutAcknowledgement = Duration.seconds(2)

	public var onlyLostAcknowledgedText: Bool {
		lostCharacters > 0 && problems.count == 1
	}

	public func adding(_ earlier: [String]) -> Verdict {
		Verdict(problems: earlier + problems, lostCharacters: lostCharacters)
	}

	public static func judge(typing: TypingLog, beforeCut: TypingLog, report: VerifierReport) -> Verdict {
		var problems: [String] = []
		for acknowledgement in typing.acknowledgements where acknowledgement.digest != TypedStream.digest(length: acknowledgement.length) {
			problems.append("acknowledgement \(acknowledgement.sequence) does not match the first \(acknowledgement.length) typed characters")
		}
		if let firstFailure = beforeCut.unsaved.first {
			problems.append("\(beforeCut.unsaved.count) saves failed before the cut, the first with \(firstFailure)")
		}
		let unacknowledged = beforeCut.typingSinceLastAcknowledgement
		if unacknowledged > longestTypingWithoutAcknowledgement {
			problems.append("typed for \(unacknowledged.milliseconds) ms before the cut without an acknowledged save")
		}
		guard report.phase == "unlocked" else {
			problems.append("the library did not unlock: \(report.phase)\(report.failure.map { ", \($0)" } ?? "")")
			return Verdict(problems: problems)
		}
		if report.integrity != "ok" {
			problems.append("integrity_check returned \(report.integrity ?? "nothing")")
		}
		if report.notes != 1 {
			problems.append("found \(report.notes) notes instead of 1")
		}
		let body = report.body ?? ""
		let acknowledged = typing.acknowledgements.map(\.length).max() ?? 0
		let lost = max(0, acknowledged - body.count)
		if !TypedStream.holds(body) {
			problems.append("the note holds text that was never typed")
		}
		if lost > 0 {
			problems.append("lost \(counted(lost, "acknowledged character")): \(body.count) on disk, \(acknowledged) acknowledged")
		}
		if body.count > typing.typed {
			problems.append("the note holds \(body.count) characters, but only \(typing.typed) were typed")
		}
		return Verdict(problems: problems, lostCharacters: lost)
	}
}

extension Duration {
	public var milliseconds: Int {
		Int(self / .milliseconds(1))
	}
}

func counted(_ count: Int, _ noun: String) -> String {
	"\(count) \(noun)\(count == 1 ? "" : "s")"
}
