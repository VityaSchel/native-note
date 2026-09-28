import Darwin
import Foundation
import Testing

@testable import PowerLossKit

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SSHLoginTests {
	private let directory: URL

	init() throws {
		directory = try temporaryDirectory()
	}

	private func login(through script: String) throws -> SSHLogin {
		let client = directory.appending(path: "ssh")
		try Data("#!/bin/sh\n\(script)\n".utf8).write(to: client)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: client.path)
		var login = SSHLogin(account: "test", address: "192.168.64.14", key: directory.appending(path: "ssh-key"))
		login.client = client
		return login
	}

	@Test func theAgentStartsWithTheCommandTheSudoersRuleAllows() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let login = try login(through: #"for last; do :; done; read request; echo "$last"; [ "$request" = hello ] && echo ready"#)
		let session = try login.session(running: SSHLogin.startAgent)
		defer { session.close() }

		try session.send(.hello)

		#expect(await session.wait(within: .seconds(10)) { session.replies.contains(.ready) })
		#expect(session.lines == ["sudo -n /usr/local/libexec/native-note-power-loss/start-agent.sh --stdio", "ready"])
	}

	@Test func theAgentLogIsReadWithoutSudo() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let login = try login(through: #"printf '%s\n' "$@""#)

		let lines = try await login.lines(of: SSHLogin.tailAgentLog, within: .seconds(10))

		#expect(lines.last == "tail -n 40 /var/log/native-note-power-loss-agent.log")
		#expect(lines.contains("test@192.168.64.14"))
		#expect(lines.contains("BatchMode=yes"))
		#expect(!lines.contains { $0.contains("sudo") })
	}

	@Test func anEmptyLogReadsAsNoLines() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let login = try login(through: "exit 0")

		#expect(try await login.lines(of: SSHLogin.tailAgentLog, within: .seconds(10)) == [])
	}

	@Test func aCommandThatNeverFinishesIsStoppedAtItsLimit() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let login = try login(through: #"echo $$; echo "ssh: still waiting" >&2; exec sleep 30"#)
		let started = ContinuousClock.now

		let lines = try await login.lines(of: SSHLogin.tailAgentLog, within: .seconds(2))

		#expect(ContinuousClock.now - started < .seconds(6))
		#expect(lines.dropFirst() == ["ssh: still waiting", "(ssh did not finish within 2.0 seconds)"])
		let pid = try #require(lines.first.flatMap { pid_t($0) })
		let deadline = ContinuousClock.now + .seconds(2)
		while kill(pid, 0) == 0, ContinuousClock.now < deadline {
			try await Task.sleep(for: .milliseconds(10))
		}
		#expect(kill(pid, 0) != 0)
	}
}
