import Testing

@testable import PowerLossKit

struct RunOptionsTests {
	@Test func onlyTheCountIsRequired() throws {
		let options = try RunOptions(["--count", "3"], defaultSeed: 77)

		#expect(options.count == 3)
		#expect(options.seed == 77)
		#expect(options.tearing)
		#expect(options.control == nil)
	}

	@Test func everyOptionIsRead() throws {
		let options = try RunOptions(["--tear", "off", "--seed", "18446744073709551615", "--count", "40", "--control", "early-ack"], defaultSeed: 0)

		#expect(options.count == 40)
		#expect(options.seed == .max)
		#expect(!options.tearing)
		#expect(options.control == .earlyAck)
	}

	@Test(arguments: [
		([], "--count is required"),
		(["--count"], "--count needs a value"),
		(["--count", "0"], "--count must be a positive number"),
		(["--count", "2", "--seed", "-1"], "--seed must be a number from 0 to 18446744073709551615"),
		(["--count", "2", "--tear", "yes"], "--tear must be on or off"),
		(["--count", "2", "--control", "late-ack"], "--control must be early-ack"),
		(["--count", "2", "--mode", "drop"], "unknown option --mode"),
		(["--count", "2", "--verbose", "yes"], "unknown option --verbose"),
	])
	func badOptionsAreExplained(_ arguments: [String], _ message: String) {
		#expect(throws: OptionError(message)) { try RunOptions(arguments, defaultSeed: 0) }
	}
}
