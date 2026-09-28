import Foundation

public enum Verification: Equatable, Sendable {
	case report(VerifierReport)
	case unreadable(String)

	public init(lines: [String], exitStatus: Int32?, failure: String?) {
		let tail = lines.suffix(5).joined(separator: " | ")
		if let failure {
			self = .unreadable("the guest could not open the library: \(failure)")
		} else if exitStatus == 0 {
			let json = lines.last { $0.hasPrefix("{") }
			let report = json.flatMap { try? JSONDecoder().decode(VerifierReport.self, from: Data($0.utf8)) }
			self = report.map(Verification.report) ?? .unreadable("the verifier printed no report: \(tail)")
		} else if let exitStatus {
			self = .unreadable("the verifier exited with \(exitStatus): \(tail)")
		} else {
			self = .unreadable("the verifier did not finish: \(tail)")
		}
	}

	public func verdict(typing: TypingLog, beforeCut: TypingLog) -> Verdict {
		switch self {
		case .report(let report):
			Verdict.judge(typing: typing, beforeCut: beforeCut, report: report)
		case .unreadable(let problem):
			Verdict(problems: [problem])
		}
	}
}
