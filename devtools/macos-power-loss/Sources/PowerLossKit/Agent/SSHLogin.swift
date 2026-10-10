import Foundation

public struct SSHLogin: Sendable {
	public static let agentLauncher = "/usr/local/libexec/native-note-power-loss/start-agent.sh"
	public static let agentLog = "/var/log/native-note-power-loss-agent.log"
	public static let startAgent = "sudo -n \(agentLauncher) --stdio"
	public static let tailAgentLog = "tail -n 40 \(agentLog)"

	public let account: String
	public let address: String
	public let key: URL
	var client = URL(filePath: "/usr/bin/ssh")

	public init(account: String, address: String, key: URL) {
		self.account = account
		self.address = address
		self.key = key
	}

	func arguments(running command: String) -> [String] {
		[
			"-i", key.path,
			"-o", "BatchMode=yes",
			"-o", "IdentitiesOnly=yes",
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
			"-o", "LogLevel=ERROR",
			"-o", "ConnectTimeout=5",
			"-o", "ServerAliveInterval=2",
			"-o", "ServerAliveCountMax=3",
			"\(account)@\(address)",
			command,
		]
	}

	@MainActor public func session(running command: String) throws -> AgentSession {
		let input = Pipe()
		let output = Pipe()
		try start(command, input: input, output: output, errors: FileHandle.nullDevice)
		return AgentSession(reading: output.fileHandleForReading, writing: input.fileHandleForWriting, interrupt: {
			try? input.fileHandleForWriting.close()
		})
	}

	@MainActor public func lines(of command: String, within limit: Duration) async throws -> [String] {
		let output = Pipe()
		let ssh = try start(command, input: FileHandle.nullDevice, output: output, errors: output)
		let session = AgentSession(reading: output.fileHandleForReading, writing: FileHandle.nullDevice, interrupt: {
			if ssh.isRunning { ssh.terminate() }
		})
		defer { session.close() }
		let finished = await session.wait(within: limit) { session.hasEnded }
		return finished ? session.lines : session.lines + ["(ssh did not finish within \(limit))"]
	}

	@discardableResult private func start(_ command: String, input: Any, output: Any, errors: Any) throws -> Process {
		let ssh = Process()
		ssh.executableURL = client
		ssh.arguments = arguments(running: command)
		ssh.standardInput = input
		ssh.standardOutput = output
		ssh.standardError = errors
		try ssh.run()
		return ssh
	}
}
