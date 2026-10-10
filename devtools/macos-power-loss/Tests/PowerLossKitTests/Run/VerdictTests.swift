import Testing

@testable import PowerLossKit

struct VerdictTests {
	private func typing(acknowledging lengths: [Int] = [], typed: Int = 0, unsaved: [String] = []) -> TypingLog {
		let keystrokes = (0 ..< typed).map { keystroke($0 + 1, atMilliseconds: $0 * 10) }
		return TypingLog(["start 0"] + keystrokes + lengths.enumerated().map { acknowledgement($0.offset + 1, $0.element) } + unsaved.map { "unsaved: \($0)" })
	}

	private func keystroke(_ length: Int, atMilliseconds milliseconds: Int) -> String {
		"\(length) \(UInt64(milliseconds) * 1_000_000)"
	}

	private func acknowledgement(_ sequence: Int, _ length: Int) -> String {
		"ack \(sequence) \(length) \(TypedStream.digest(length: length))"
	}

	private func onDisk(_ body: String?, integrity: String = "ok", notes: Int = 1) -> VerifierReport {
		VerifierReport(phase: "unlocked", integrity: integrity, notes: notes, body: body)
	}

	private func judge(_ log: TypingLog, report: VerifierReport) -> Verdict {
		Verdict.judge(typing: log, beforeCut: log, report: report)
	}

	@Test func aNoteHoldingEveryAcknowledgedCharacterPasses() {
		let verdict = judge(typing(acknowledging: [5, 12], typed: 20), report: onDisk(TypedStream.text(length: 15)))

		#expect(verdict == Verdict(problems: []))
		#expect(verdict.passed)
	}

	@Test func aCutBeforeTheFirstAcknowledgementMayLeaveTheNoteEmpty() {
		#expect(judge(typing(typed: 20), report: onDisk("")).passed)
	}

	@Test func typingForMoreThanTwoSecondsWithoutAnAcknowledgementBeforeTheCutFails() {
		let neverAcknowledged = judge(typing(typed: 212), report: onDisk(""))
		let acknowledgedAtTheStart = TypingLog(["start 0", keystroke(1, atMilliseconds: 0), acknowledgement(1, 1), keystroke(2, atMilliseconds: 1_000), keystroke(3, atMilliseconds: 2_500)])

		#expect(neverAcknowledged.problems == ["typed for 2110 ms before the cut without an acknowledged save"])
		#expect(judge(acknowledgedAtTheStart, report: onDisk("a")).problems == ["typed for 2500 ms before the cut without an acknowledged save"])
		#expect(judge(typing(typed: 201), report: onDisk("")).passed)
	}

	@Test func savesThatStopBeingAcknowledgedPartwayFailEvenAfterEarlierAcknowledgements() {
		let lines = ["start 0"] + (1 ... 400).map { keystroke($0, atMilliseconds: $0 * 10) }
		let stalled = TypingLog(lines[...100] + [acknowledgement(1, 50), acknowledgement(2, 100)] + lines[101...])

		#expect(judge(stalled, report: onDisk(TypedStream.text(length: 100))).problems == ["typed for 3000 ms before the cut without an acknowledged save"])
	}

	@Test func typingOnlyAfterTheCutWithoutAnAcknowledgementPasses() {
		let beforeCut = typing(acknowledging: [100], typed: 110)
		let afterStop = TypingLog(["start 0"] + (1 ... 400).map { keystroke($0, atMilliseconds: $0 * 10) } + [acknowledgement(1, 100)])

		#expect(Verdict.judge(typing: afterStop, beforeCut: beforeCut, report: onDisk(TypedStream.text(length: 100))).passed)
	}

	@Test func aSaveThatFailedBeforeTheCutFails() {
		let verdict = judge(typing(acknowledging: [3], typed: 20, unsaved: ["Optional(saveFailed)", "Optional(saveFailed)"]), report: onDisk(TypedStream.text(length: 3)))

		#expect(verdict.problems == ["2 saves failed before the cut, the first with Optional(saveFailed)"])
	}

	@Test func aSaveThatFailsOnlyAfterTheCutPasses() {
		let verdict = Verdict.judge(typing: typing(acknowledging: [3], typed: 20, unsaved: ["Optional(saveFailed)"]), beforeCut: typing(acknowledging: [3], typed: 15), report: onDisk(TypedStream.text(length: 3)))

		#expect(verdict.passed)
	}

	@Test func lostAcknowledgedCharactersFailAndAreCounted() {
		let verdict = judge(typing(acknowledging: [5, 12], typed: 20), report: onDisk(TypedStream.text(length: 10)))

		#expect(verdict.problems == ["lost 2 acknowledged characters: 10 on disk, 12 acknowledged"])
		#expect(verdict.lostCharacters == 2)
		#expect(verdict.onlyLostAcknowledgedText)
		#expect(!verdict.adding(["the typist exited with 1 before the cut"]).onlyLostAcknowledgedText)
		#expect(verdict.adding(["the typist exited with 1 before the cut"]).lostCharacters == 2)
	}

	@Test func anAcknowledgementThatArrivesAfterTheCutMustBeOnDiskToo() {
		let verdict = Verdict.judge(typing: typing(acknowledging: [5, 9], typed: 12), beforeCut: typing(acknowledging: [5], typed: 8), report: onDisk(TypedStream.text(length: 7)))

		#expect(verdict.problems == ["lost 2 acknowledged characters: 7 on disk, 9 acknowledged"])
	}

	@Test func oneLostCharacterIsCountedInTheSingular() {
		let verdict = judge(typing(acknowledging: [5], typed: 6), report: onDisk(TypedStream.text(length: 4)))

		#expect(verdict.problems == ["lost 1 acknowledged character: 4 on disk, 5 acknowledged"])
	}

	@Test func textThatWasNeverTypedFails() {
		let verdict = judge(typing(acknowledging: [3], typed: 20), report: onDisk("abcx"))

		#expect(verdict.problems == ["the note holds text that was never typed"])
	}

	@Test func aNoteLongerThanEverythingTypedUntilTheVMStoppedFails() {
		let verdict = Verdict.judge(typing: typing(acknowledging: [3], typed: 5), beforeCut: typing(acknowledging: [3], typed: 4), report: onDisk(TypedStream.text(length: 6)))

		#expect(verdict.problems == ["the note holds 6 characters, but only 5 were typed"])
		#expect(Verdict.judge(typing: typing(acknowledging: [3], typed: 6), beforeCut: typing(acknowledging: [3], typed: 4), report: onDisk(TypedStream.text(length: 6))).passed)
	}

	@Test func aDamagedDatabaseFails() {
		let verdict = judge(typing(typed: 5), report: onDisk("", integrity: "*** in database main ***", notes: 0))

		#expect(verdict.problems == ["integrity_check returned *** in database main ***", "found 0 notes instead of 1"])
	}

	@Test func aLibraryThatNoLongerUnlocksFails() {
		let report = VerifierReport(phase: "locked", failure: "unexpected(\"The notes database is missing.\")", notes: 0)
		let verdict = judge(typing(acknowledging: [1], typed: 5), report: report)

		#expect(verdict.problems == ["the library did not unlock: locked, unexpected(\"The notes database is missing.\")"])
	}

	@Test func anAcknowledgementThatDoesNotMatchTheTypedStreamFails() {
		let forged = TypingLog(["start 0", "ack 1 4 \(TypedStream.digest(length: 5))"])
		let verdict = judge(forged, report: onDisk("abcd"))

		#expect(verdict.problems == ["acknowledgement 1 does not match the first 4 typed characters"])
	}
}
