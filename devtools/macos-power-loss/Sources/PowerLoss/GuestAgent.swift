import Foundation
import PowerLossKit
import Virtualization

extension Machine {
	func openAgent(_ request: AgentRequest, payload: Data = Data()) async throws -> AgentSession {
		let connection = try await connect(toPort: AgentRequest.port)
		let descriptor = connection.fileDescriptor
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		let session = AgentSession(reading: handle, writing: handle, interrupt: { shutdown(descriptor, SHUT_RDWR) }, release: { connection.close() })
		try session.send(request, payload: payload)
		return session
	}

	func waitForAgent(within timeout: Duration) async throws {
		try await AgentReadiness.wait(within: timeout, stopReason: { self.hasStopped ? self.stopReason ?? "unknown reason" : nil }) {
			try await self.openAgent(.hello)
		}
	}

	func pushKit(from folder: URL) async throws {
		let archive = try LocalKit.archive(from: folder)
		let session = try await openAgent(.install(byteCount: archive.count), payload: archive)
		defer { session.close() }
		_ = await session.wait(within: .seconds(120)) { session.replies.contains(.done) || session.failure != nil }
		guard session.replies.contains(.done) else {
			throw HarnessError("copying the typist into the VM failed:\n\(session.lines.joined(separator: "\n"))")
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
