import Testing

@testable import PowerLossKit

struct VerificationTests {
	@Test func theTypistsReportIsReadFromItsLastJSONLine() {
		let lines = [#"{"body":"abcdef","integrity":"ok","notes":1,"phase":"unlocked","walCheckpoints":2}"#, "exit 0"]

		let verification = Verification(lines: lines, exitStatus: 0, failure: nil)

		#expect(verification == .report(VerifierReport(phase: "unlocked", integrity: "ok", notes: 1, body: "abcdef", walCheckpoints: 2)))
		#expect(NoteOnDisk(VerifierReport(phase: "unlocked", integrity: "ok", notes: 1, body: "abcdef", walCheckpoints: 2)).walCheckpoints == 2)
	}

	@Test func aLockedLibraryReportsWithoutABody() {
		let lines = [#"{"failure":"wrongPassword","notes":0,"phase":"locked"}"#, "exit 0"]

		let verification = Verification(lines: lines, exitStatus: 0, failure: nil)

		#expect(verification == .report(VerifierReport(phase: "locked", failure: "wrongPassword", notes: 0)))
		#expect(verification.verdict(typing: TypingLog([]), beforeCut: TypingLog([])).problems == ["the library did not unlock: locked, wrongPassword"])
	}

	@Test func aVerifierThatFailsIsUnreadable() {
		let lines = ["Fatal error: out of memory", "exit 134"]

		let verification = Verification(lines: lines, exitStatus: 134, failure: nil)

		#expect(verification == .unreadable("the verifier exited with 134: Fatal error: out of memory | exit 134"))
		#expect(verification.verdict(typing: TypingLog([]), beforeCut: TypingLog([])) == Verdict(problems: ["the verifier exited with 134: Fatal error: out of memory | exit 134"]))
	}

	@Test func aVerifierThatNeverFinishesIsUnreadable() {
		#expect(Verification(lines: ["{\"phase\":"], exitStatus: nil, failure: nil) == .unreadable("the verifier did not finish: {\"phase\":"))
	}

	@Test func anAgentFailureComesFirst() {
		#expect(Verification(lines: [], exitStatus: nil, failure: "the PowerLossLibrary volume is not mounted") == .unreadable("the guest could not open the library: the PowerLossLibrary volume is not mounted"))
	}

	@Test func aReportThatDoesNotDecodeIsUnreadable() {
		#expect(Verification(lines: ["{\"notes\":\"one\"}", "exit 0"], exitStatus: 0, failure: nil) == .unreadable("the verifier printed no report: {\"notes\":\"one\"} | exit 0"))
	}
}
