import Testing

@testable import PowerLossKit

struct AgentRequestTests {
	@Test(arguments: [
		AgentRequest.hello,
		.shutdown,
		.prepare(password: "power loss"),
		.type(password: "power loss"),
		.type(password: "power loss", control: .earlyAck),
		.verify(password: "a b  c"),
		.install(byteCount: 4096),
		.diagnose,
		.probe(.library),
		.probe(.system),
	])
	func aRequestSurvivesItsOwnLine(_ request: AgentRequest) {
		#expect(AgentRequest(line: request.line) == request)
	}

	@Test(arguments: ["", "hello there", "shutdown now", "type", "type ", "type-early-ack", "type-late-ack power loss", "type- power loss", "verify", "format disk0", "install", "install 0", "install -3", "install many", "diagnose all", "probe", "probe boot"])
	func malformedRequestsAreRefused(_ line: String) {
		#expect(AgentRequest(line: line) == nil)
	}

	@Test func aControlTypingRequestNamesItsControl() {
		#expect(AgentRequest.type(password: "power loss", control: .earlyAck).line == "type-early-ack power loss")
		#expect(AgentRequest(line: "type-early-ack power loss") == .type(password: "power loss", control: .earlyAck))
	}

	@Test func probeRequestsNameTheirVolume() {
		#expect(AgentRequest.probe(.library).line == "probe library")
		#expect(AgentRequest.probe(.system).line == "probe system")
	}

	@Test func typingRequestsNameTheTypistMode() {
		#expect(AgentRequest.prepare(password: "p").typistArguments! == ("prepare", "p"))
		#expect(AgentRequest.type(password: "p").typistArguments! == ("acknowledge", "p"))
		#expect(AgentRequest.type(password: "p", control: .earlyAck).typistArguments! == ("acknowledge-before-saving", "p"))
		#expect(AgentRequest.verify(password: "p").typistArguments! == ("verify", "p"))
		#expect(AgentRequest.hello.typistArguments == nil)
		#expect(AgentRequest.shutdown.typistArguments == nil)
		#expect(AgentRequest.install(byteCount: 1).typistArguments == nil)
		#expect(AgentRequest.diagnose.typistArguments == nil)
		#expect(AgentRequest.probe(.library).typistArguments == nil)
	}

	@Test func repliesAreToldApartFromTypistOutput() {
		#expect(AgentReply(line: "ready") == .ready)
		#expect(AgentReply(line: "ok") == .done)
		#expect(AgentReply(line: "exit 0") == .exit(0))
		#expect(AgentReply(line: "exit -1") == .exit(-1))
		#expect(AgentReply(line: "error volume missing") == .failure("volume missing"))
		#expect(AgentReply(line: "exit soon") == .output("exit soon"))
		#expect(AgentReply(line: "ack 1 2 ab") == .output("ack 1 2 ab"))
	}

	@Test func aFailureStaysOnOneLine() {
		#expect(AgentReply.failure("diskutil failed\nsecond line").line == "error diskutil failed second line")
		#expect(AgentReply(line: AgentReply.exit(3).line) == .exit(3))
	}
}
