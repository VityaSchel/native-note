import Testing

@testable import PowerLossKit

struct TypistLineTests {
	private let digest = String(repeating: "a", count: 64)

	@Test func everyTypistLineIsRecognized() {
		#expect(TypistLine("start 12") == .start(length: 12))
		#expect(TypistLine("13 918273645") == .keystroke(length: 13, uptimeNanoseconds: 918_273_645))
		#expect(TypistLine("ack 2 13 \(digest)") == .acknowledged(Acknowledgement(sequence: 2, length: 13, digest: digest)))
		#expect(TypistLine("prepared 1") == .prepared(notes: 1))
		#expect(TypistLine("unsaved: Optional(unexpected(\"disk I/O error\"))") == .unsaved("Optional(unexpected(\"disk I/O error\"))"))
	}

	@Test(arguments: ["locked: Optional(wrongPassword)", "start", "start x", "ack 1 2 short", "ack 1 x \(String(repeating: "a", count: 64))", "13", "13 -5", "exit 0", ""])
	func anythingElseIsKeptAsIs(_ line: String) {
		#expect(TypistLine(line) == .other(line))
	}

	@Test func theLogKeepsTheFurthestTypedLengthAndEveryAcknowledgement() {
		let log = TypingLog(["start 3", "4 1", "5 2", "ack 1 5 \(digest)", "6 3", "locked?", "unsaved: nil", "ack 2 6 \(digest)", "7 4"])

		#expect(log.start == 3)
		#expect(log.typed == 7)
		#expect(log.acknowledgements.map(\.length) == [5, 6])
		#expect(log.acknowledged == 6)
		#expect(log.unsaved == ["nil"])
		#expect(log.unexpected == ["locked?"])
	}

	@Test func theLogTimesTheTypistsLongestPauseAndItsTypingSinceTheLastAcknowledgementOnTheGuestClock() {
		let log = TypingLog(["start 3", "4 1000000000", "5 1040000000", "ack 1 5 \(digest)", "6 1340000000", "7 1380000000", "8 1420000000"])

		#expect(log.longestPauseBetweenKeystrokes == .milliseconds(300))
		#expect(log.typingSinceLastAcknowledgement == .milliseconds(380))
		#expect(TypingLog(["start 0", "1 500000000", "2 900000000"]).typingSinceLastAcknowledgement == .milliseconds(400))
		#expect(TypingLog(["start 0"]).typingSinceLastAcknowledgement == .zero)
	}

	@Test func beforeTheFirstAcknowledgementOnlyTheStartIsAcknowledged() {
		#expect(TypingLog(["start 4", "5 1"]).acknowledged == 4)
		#expect(TypingLog([]).acknowledged == 0)
		#expect(TypingLog([]).start == nil)
	}

	@Test func theTypedStreamCyclesTheAlphabet() {
		#expect(TypedStream.text(length: 0) == "")
		#expect(TypedStream.text(length: 28) == "abcdefghijklmnopqrstuvwxyzab")
		#expect(TypedStream.holds("abcd"))
		#expect(TypedStream.holds(""))
		#expect(!TypedStream.holds("abce"))
		#expect(TypedStream.digest(length: 3) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	}
}
