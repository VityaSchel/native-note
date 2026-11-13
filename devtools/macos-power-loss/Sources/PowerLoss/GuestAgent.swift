import Foundation
import PowerLossKit
import Virtualization

extension Machine {
	func openAgent(_ request: AgentRequest) async throws -> AgentSession {
		let connection = try await connect(toPort: AgentRequest.port)
		let descriptor = connection.fileDescriptor
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		let session = AgentSession(reading: handle, writing: handle, interrupt: { shutdown(descriptor, SHUT_RDWR) }, release: { connection.close() })
		try session.send(request)
		return session
	}

	func waitForAgent(within timeout: Duration) async throws {
		try await AgentReadiness.wait(within: timeout, stopReason: { self.hasStopped ? self.stopReason ?? "unknown reason" : nil }) {
			try await self.openAgent(.hello)
		}
	}

	func shutDownGuest() async {
		if let session = try? await withTimeLimit(.seconds(10), discardingLate: { $0.close() }, { try await self.openAgent(.shutdown) }) {
			_ = await session.wait(within: .seconds(10)) { session.replies.contains(.done) }
			session.close()
		}
		if await !waitUntilStopped(within: .seconds(120)) {
			say("vm: the guest did not shut down within 120 s, powering off")
			await powerOff()
		}
	}
}
