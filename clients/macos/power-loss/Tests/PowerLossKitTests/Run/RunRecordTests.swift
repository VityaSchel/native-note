import Foundation
import Testing

@testable import PowerLossKit

struct RunRecordTests {
	private func record(_ number: Int, tearSeed: UInt64? = 11, control: TypistControl? = nil, verdict: Verdict = Verdict(problems: []), torn: TornWrite? = nil, checkpoints: Int = 0) -> RunRecord {
		var record = RunRecord(seed: 5, run: PlannedRun(number: number, cutAfterMilliseconds: 1_500, tearSeed: tearSeed), control: control, date: .now)
		record.typed = 150
		record.typedAfterCut = 3
		record.acknowledgedAfterCut = 1
		record.acknowledged = 120
		record.cut = CutReport(torn: torn, dropped: DiskActivity(reads: 1, writes: 2))
		record.disk = NoteOnDisk(VerifierReport(phase: "unlocked", integrity: "ok", notes: 1, body: TypedStream.text(length: 130), walCheckpoints: checkpoints))
		record.verdict = verdict
		return record
	}

	@Test func aRecordIsOneJSONLineThatReadsBack() throws {
		var record = RunRecord(seed: 5, run: RunPlan.make(seed: 5, count: 2)[1], control: .earlyAck, date: Date(timeIntervalSince1970: 1_790_000_000))
		record.typed = 40
		record.acknowledged = 30
		record.cut = CutReport(torn: TornWrite(offset: 4_096, length: 8_192, kept: 4_096, zeroes: true, millisecondsAfterCut: 12), dropped: DiskActivity(writes: 3))
		record.longestSilenceWhileTyping = 310
		record.longestKeystrokePauseWhileTyping = 52
		record.verdict = Verdict(problems: ["lost 2 acknowledged characters"], lostCharacters: 2)

		#expect(!record.jsonLine.contains("\n"))
		#expect(record.date == "2026-09-21T14:13:20Z")
		#expect(try JSONDecoder().decode(RunRecord.self, from: Data(record.jsonLine.utf8)) == record)
	}

	@Test func aRecordStartsAsUnfinished() {
		let record = RunRecord(seed: 5, run: PlannedRun(number: 1, cutAfterMilliseconds: 300, tearSeed: nil), date: .now)

		#expect(!record.verdict.passed)
	}

	@Test func aRunIsSummedUpInOneLine() {
		var torn = record(3, torn: TornWrite(offset: 8_192, length: 16_384, kept: 4_096, millisecondsAfterCut: 37), checkpoints: 2)
		torn.longestSilenceWhileTyping = 120
		torn.longestKeystrokePauseWhileTyping = 45

		#expect(torn.summary == "run 3: passed; cut 1500 ms after typing started; 120 acknowledged, 130 on disk, 150 typed; after the cut 3 typed and 1 acknowledgement arrived; tore the 16384-byte write at 8192 that arrived 37 ms after the cut, keeping 4096; dropped after the cut: reads 1, writes 2; 2 WAL checkpoints; integrity ok; the volume mounted and the database opened; no keepalive while typing, heard nothing for up to 120 ms, the typist paused up to 45 ms between keystrokes")
		#expect(record(1, torn: TornWrite(offset: 0, length: 8_192, kept: 0, zeroes: true, millisecondsAfterCut: 5)).summary.contains("; tore the 8192-byte zeroing at 0 that arrived 5 ms after the cut, keeping 0;"))
		#expect(record(1).summary.contains("; no change reached the disk after the cut, nothing torn;"))
		#expect(record(1, checkpoints: 1).summary.contains("; 1 WAL checkpoint;"))
		#expect(record(1, tearSeed: nil).summary.contains("; tearing off;"))
	}

	@Test func aRunWithoutAVerifierReportSaysSo() {
		var failed = record(2, verdict: Verdict(problems: ["the guest could not open the library: the PowerLossLibrary volume is not mounted"]))
		failed.disk = nil

		#expect(failed.summary.hasPrefix("run 2: FAILED: the guest could not open the library: the PowerLossLibrary volume is not mounted; "))
		failed.keepAlivesWhileTyping = 2
		#expect(failed.summary.hasSuffix("; ? WAL checkpoints; integrity not checked; the verifier gave no report; kept alive 2 times while typing, heard nothing for up to 0 ms, the typist paused up to 0 ms between keystrokes"))
	}

	@Test func aSummaryCountsPassesCheckpointsAndTears() {
		let summary = RunSummary([
			record(1, torn: TornWrite(offset: 0, length: 8_192, kept: 4_096)),
			record(2, torn: TornWrite(offset: 0, length: 4_096, kept: 0), checkpoints: 1),
			record(3, verdict: Verdict(problems: ["integrity_check returned nothing"])),
		], control: nil)

		#expect(!summary.succeeded)
		#expect(summary.line == "2 of 3 runs passed, 1 cut after a WAL checkpoint, 2 tore the first change after the cut, 1 of them partway")
	}

	@Test func aControlSucceedsOnlyWhenEveryRunLostAcknowledgedTextAndNothingElse() {
		let lost = Verdict(problems: ["lost 9 acknowledged characters: 120 on disk, 129 acknowledged"], lostCharacters: 9)
		let lostAndDamaged = Verdict(problems: ["integrity_check returned nothing", "lost 9 acknowledged characters"], lostCharacters: 9)
		let caught = RunSummary([record(1, control: .earlyAck, verdict: lost), record(2, control: .earlyAck, verdict: lost)], control: .earlyAck)
		let missed = RunSummary([record(1, control: .earlyAck, verdict: lost), record(2, control: .earlyAck), record(3, control: .earlyAck, verdict: lostAndDamaged)], control: .earlyAck)

		#expect(caught.succeeded)
		#expect(caught.line == "control early-ack failed as expected: all 2 runs lost acknowledged text and nothing else; 0 cut after a WAL checkpoint, 0 tore the first change after the cut, 0 of them partway")
		#expect(!missed.succeeded)
		#expect(missed.line.hasPrefix("control early-ack did NOT fail as expected: runs 2, 3 of 3 did not fail by losing acknowledged text alone; "))
		#expect(record(1, control: .earlyAck, verdict: lost).summary.hasPrefix("control run 1: FAILED: lost 9 acknowledged characters"))
	}
}
