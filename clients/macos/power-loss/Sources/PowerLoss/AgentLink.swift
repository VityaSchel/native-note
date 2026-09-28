import Foundation
import PowerLossKit
import Virtualization

struct AgentLink: CustomStringConvertible {
	enum Transport {
		case vsock
		case ssh(account: String, key: URL)
	}

	static let leases = URL(fileURLWithPath: "/var/db/dhcpd_leases")

	let transport: Transport

	init(_ kind: AgentTransport, layout: Layout) throws {
		switch kind {
		case .vsock: transport = .vsock
		case .ssh: transport = .ssh(account: try layout.setUpAccount(), key: layout.sshKey)
		}
	}

	var kind: AgentTransport {
		switch transport {
		case .vsock: .vsock
		case .ssh: .ssh
		}
	}

	var description: String {
		switch transport {
		case .vsock: "vsock port \(AgentRequest.port)"
		case .ssh(let account, _): "SSH as \(account)"
		}
	}

	static func firstAnswering(_ kinds: [AgentTransport], layout: Layout, on machine: Machine, within timeout: Duration) async -> AgentLink? {
		for kind in kinds {
			do {
				let link = try AgentLink(kind, layout: layout)
				try await link.waitUntilReady(on: machine, within: timeout)
				return link
			} catch {
				say("agent: no answer over \(kind.rawValue): \(error)")
			}
		}
		return nil
	}

	func open(_ request: AgentRequest, on machine: Machine, payload: Data = Data()) async throws -> AgentSession {
		let session: AgentSession
		switch transport {
		case .vsock:
			let connection = try await machine.connect(toPort: AgentRequest.port)
			let descriptor = connection.fileDescriptor
			let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
			session = AgentSession(reading: handle, writing: handle, interrupt: { shutdown(descriptor, SHUT_RDWR) }, release: { connection.close() })
		case .ssh(let account, let key):
			session = try Self.login(account, key: key).session(running: SSHLogin.startAgent)
		}
		try session.send(request, payload: payload)
		return session
	}

	func waitUntilReady(on machine: Machine, within timeout: Duration) async throws {
		do {
			try await AgentReadiness.wait(within: timeout, stopReason: { machine.hasStopped ? machine.stopReason ?? "unknown reason" : nil }) {
				try await open(.hello, on: machine)
			}
		} catch .silent {
			throw HarnessError("the guest agent did not answer over \(self) within \(timeout)")
		}
	}

	private static func login(_ account: String, key: URL) throws -> SSHLogin {
		let leases = String(decoding: try Data(contentsOf: Self.leases), as: UTF8.self)
		guard let address = DHCPLeases.address(of: MachineConfiguration.macAddress, in: leases) else {
			throw HarnessError("the VM has no DHCP lease yet")
		}
		return SSHLogin(account: account, address: address, key: key)
	}

	func pushKit(_ layout: Layout, on machine: Machine) async throws {
		let archive = try LocalKit.archive(from: layout.kit)
		let session = try await open(.install(byteCount: archive.count), on: machine, payload: archive)
		defer { session.close() }
		_ = await session.wait(within: .seconds(120)) { session.replies.contains(.done) || session.failure != nil }
		guard session.replies.contains(.done) else {
			throw HarnessError("copying the typist and the probe into the VM failed:\n\(session.lines.joined(separator: "\n"))")
		}
	}

	static func recentLog(_ layout: Layout) async -> [String] {
		do {
			return try await login(try layout.setUpAccount(), key: layout.sshKey).lines(of: SSHLogin.tailAgentLog, within: .seconds(20))
		} catch {
			return ["\(error)"]
		}
	}

	func shutDown(_ machine: Machine) async {
		if let session = try? await withTimeLimit(.seconds(10), discardingLate: { $0.close() }, { try await open(.shutdown, on: machine) }) {
			_ = await session.wait(within: .seconds(10)) { session.replies.contains(.done) }
			session.close()
		}
		if await !machine.waitUntilStopped(within: .seconds(120)) {
			say("vm: the guest did not shut down within 120 s, powering off")
			await machine.powerOff()
		}
	}
}
