import Foundation
import Testing

@testable import PowerLossKit

struct AgentLogTests {
	private let moment = Date(timeIntervalSince1970: 1_790_000_000)

	@Test func theAgentSaysWhenItStartedListening() {
		#expect(AgentLog.listening(on: AgentRequest.port, at: moment) == "power-loss-agent: 2026-09-21T14:13:20Z listening on vsock port 7040\n")
	}

	@Test func everyAgentLineCarriesItsTime() {
		#expect(AgentLog.line("vsock port 7040 failed with errno 48", at: moment) == "power-loss-agent: 2026-09-21T14:13:20Z vsock port 7040 failed with errno 48\n")
	}

	@Test func anEmptyTailSaysTheAgentWroteNothing() {
		#expect(AgentLog.shown([]) == ["(empty: the agent has written nothing since the setup script restarted it)"])
		#expect(AgentLog.shown(["power-loss-agent: 2026-09-21T14:13:20Z listening on vsock port 7040"]) == ["power-loss-agent: 2026-09-21T14:13:20Z listening on vsock port 7040"])
	}
}
