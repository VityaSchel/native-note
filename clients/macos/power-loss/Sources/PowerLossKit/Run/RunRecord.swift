import Foundation

public struct NoteOnDisk: Codable, Equatable, Sendable {
	public let phase: String
	public let failure: String?
	public let integrity: String?
	public let notes: Int
	public let length: Int?
	public let walCheckpoints: Int?

	public init(_ report: VerifierReport) {
		phase = report.phase
		failure = report.failure
		integrity = report.integrity
		notes = report.notes
		length = report.body?.count
		walCheckpoints = report.walCheckpoints
	}
}

public struct RunRecord: Codable, Equatable, Sendable {
	public let seed: UInt64
	public let run: PlannedRun
	public let control: TypistControl?
	public let date: String
	public var typed = 0
	public var typedAfterCut = 0
	public var acknowledgements = 0
	public var acknowledgedAfterCut = 0
	public var acknowledged = 0
	public var activity: DiskActivity?
	public var keepAlivesWhileTyping = 0
	public var longestSilenceWhileTyping = 0
	public var longestKeystrokePauseWhileTyping = 0
	public var cut: CutReport?
	public var disk: NoteOnDisk?
	public var unexpectedOutput: [String] = []
	public var verdict = Verdict(problems: ["the run did not finish"])

	public init(seed: UInt64, run: PlannedRun, control: TypistControl? = nil, date: Date) {
		self.seed = seed
		self.run = run
		self.control = control
		self.date = date.formatted(.iso8601)
	}

	public var jsonLine: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
	}

	public var summary: String {
		let outcome = verdict.passed ? "passed" : "FAILED: \(verdict.problems.joined(separator: "; "))"
		let lengthOnDisk = disk?.length.map(String.init) ?? "?"
		return [
			"\(control == nil ? "" : "control ")run \(run.number): \(outcome)",
			"cut \(run.cutAfterMilliseconds) ms after typing started",
			"\(acknowledged) acknowledged, \(lengthOnDisk) on disk, \(typed) typed",
			"after the cut \(typedAfterCut) typed and \(counted(acknowledgedAfterCut, "acknowledgement")) arrived",
			tearing,
			"dropped after the cut: \(cut?.dropped.summary ?? "?")",
			disk?.walCheckpoints.map { counted($0, "WAL checkpoint") } ?? "? WAL checkpoints",
			"integrity \(disk?.integrity ?? "not checked")",
			opening,
			stalls,
		].joined(separator: "; ")
	}

	private var tearing: String {
		guard run.tearSeed != nil else { return "tearing off" }
		guard let cut else { return "tear unknown" }
		guard let torn = cut.torn else { return "no change reached the disk after the cut, nothing torn" }
		return "tore the \(torn.length)-byte \(torn.zeroes ? "zeroing" : "write") at \(torn.offset) that arrived \(torn.millisecondsAfterCut) ms after the cut, keeping \(torn.kept)"
	}

	private var stalls: String {
		let keptAlive = keepAlivesWhileTyping == 0 ? "no keepalive while typing" : "kept alive \(counted(keepAlivesWhileTyping, "time")) while typing"
		return "\(keptAlive), heard nothing for up to \(longestSilenceWhileTyping) ms, the typist paused up to \(longestKeystrokePauseWhileTyping) ms between keystrokes"
	}

	private var opening: String {
		guard let disk else { return "the verifier gave no report" }
		return disk.phase == "unlocked" ? "the volume mounted and the database opened" : "the volume mounted, the library \(disk.phase)"
	}
}

public struct RunSummary: Equatable, Sendable {
	public let runs: Int
	public let passed: Int
	public let afterCheckpoint: Int
	public let torn: Int
	public let tornPartway: Int
	public let control: TypistControl?
	public let controlMisses: [Int]

	public init(_ records: [RunRecord], control: TypistControl?) {
		runs = records.count
		passed = records.count(where: { $0.verdict.passed })
		afterCheckpoint = records.count(where: { ($0.disk?.walCheckpoints ?? 0) > 0 })
		let tears = records.compactMap { $0.cut?.torn }
		torn = tears.count
		tornPartway = tears.count(where: { 0 < $0.kept && $0.kept < $0.length })
		self.control = control
		controlMisses = control == nil ? [] : records.filter { !$0.verdict.onlyLostAcknowledgedText }.map(\.run.number)
	}

	public var succeeded: Bool {
		control == nil ? passed == runs : controlMisses.isEmpty
	}

	public var line: String {
		let counts = "\(afterCheckpoint) cut after a WAL checkpoint, \(torn) tore the first change after the cut, \(tornPartway) of them partway"
		guard let control else { return "\(passed) of \(runs) runs passed, \(counts)" }
		guard controlMisses.isEmpty else {
			let misses = controlMisses.map(String.init).joined(separator: ", ")
			return "control \(control.rawValue) did NOT fail as expected: runs \(misses) of \(runs) did not fail by losing acknowledged text alone; \(counts)"
		}
		return "control \(control.rawValue) failed as expected: all \(runs) runs lost acknowledged text and nothing else; \(counts)"
	}
}
