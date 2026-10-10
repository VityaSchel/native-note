import Darwin
import Foundation
import Testing

@testable import PowerLossKit

private struct VolumeMissing: Error, CustomStringConvertible {
	let description = "the PowerLossLibrary volume is not mounted"
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct AgentSessionTests {
	private let directory: URL

	init() throws {
		directory = try temporaryDirectory()
	}

	private func service(typing script: String, library: @escaping @Sendable () throws -> URL) throws -> AgentService {
		let typist = directory.appending(path: "typist")
		try Data("#!/bin/sh\n\(script)\n".utf8).write(to: typist)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: typist.path)
		return AgentService(typist: typist, libraryDirectory: library, shutDown: {})
	}

	private func connect(to service: AgentService) throws -> AgentSession {
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, guest) = (ends[0], ends[1])
		Thread {
			service.serve(input: guest, output: guest)
			close(guest)
		}.start()
		let handle = FileHandle(fileDescriptor: host, closeOnDealloc: false)
		return AgentSession(reading: handle, writing: handle, interrupt: { shutdown(host, SHUT_RDWR) }, release: { close(host) })
	}

	@Test func helloIsAnsweredWithReady() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let session = try connect(to: try service(typing: "exit 9") { throw VolumeMissing() })
		defer { session.close() }

		try session.send(.hello)

		#expect(await session.wait(within: .seconds(10)) { session.replies.contains(.ready) })
	}

	@Test func closingReleasesTheConnectionEvenWhenThePeerNeverWrites() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let silent = Pipe()
		let requests = Pipe()
		var released = false
		let session = AgentSession(reading: silent.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, release: { released = true })
		try session.send(.hello)
		#expect(await !session.wait(within: .milliseconds(100)) { session.replies.contains(.ready) })

		session.close()

		#expect(await session.wait(within: .seconds(2)) { released })
		#expect(session.hasEnded)
		withExtendedLifetime(silent) {}
	}

	@Test func closingASessionThePeerEndedLeavesTheReleasedConnectionAlone() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, guest) = (ends[0], ends[1])
		var interrupts = 0
		let handle = FileHandle(fileDescriptor: host, closeOnDealloc: false)
		let session = AgentSession(reading: handle, writing: handle, interrupt: { interrupts += 1 }, release: { close(host) })
		close(guest)
		#expect(await session.wait(within: .seconds(5)) { session.hasEnded })

		session.close()

		#expect(interrupts == 0)
	}

	@Test func aSilentSessionDoesNotHoldUpTheNextOne() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let silent = Pipe()
		let requests = Pipe()
		let stuck = AgentSession(reading: silent.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {})
		defer { stuck.close() }
		_ = await stuck.wait(within: .milliseconds(100)) { false }
		let session = try connect(to: try service(typing: "exit 9") { throw VolumeMissing() })
		defer { session.close() }

		try session.send(.hello)

		#expect(await session.wait(within: .seconds(5)) { session.replies.contains(.ready) })
		withExtendedLifetime(silent) {}
	}

	@Test func aTypingSessionCollectsEveryTypistLineAndTheExitStatus() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let digest = TypedStream.digest(length: 2)
		let library = directory
		let session = try connect(to: try service(typing: "echo 'start 0'; echo '1 100'; echo '2 200'; echo 'ack 1 2 \(digest)'; exit 0") { library })
		defer { session.close() }

		try session.send(.type(password: "power loss"))
		let status = try await session.waitForExit(within: .seconds(10))
		_ = await session.wait(within: .seconds(10)) { false }

		#expect(status == 0)
		#expect(session.hasEnded)
		#expect(session.lines == ["start 0", "1 100", "2 200", "ack 1 2 \(digest)", "exit 0"])
		#expect(TypingLog(session.lines).acknowledgements == [Acknowledgement(sequence: 1, length: 2, digest: digest)])
	}

	@Test func anAgentFailureIsThrown() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let session = try connect(to: try service(typing: "exit 9") { throw VolumeMissing() })
		defer { session.close() }

		try session.send(.verify(password: "power loss"))

		await #expect(throws: AgentSession.Failure.agent("the PowerLossLibrary volume is not mounted")) {
			try await session.waitForExit(within: .seconds(10))
		}
	}

	@Test func aTypistThatDoesNotFinishInTimeIsReportedWithItsLastLines() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let library = directory
		let session = try connect(to: try service(typing: "echo 'start 0'; sleep 2") { library })
		defer { session.close() }

		try session.send(.type(password: "power loss"))
		_ = await session.wait(within: .seconds(10)) { !session.lines.isEmpty }

		await #expect(throws: AgentSession.Failure.unfinished(.milliseconds(100), lastLines: ["start 0"])) {
			try await session.waitForExit(within: .milliseconds(100))
		}
	}

	@Test func followingHandsOverEachLineInTimeToPaceTheProbeThroughKeepalives() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let probe = directory.appending(path: "probe")
		try Data("#!/bin/sh\nsleep 0.5\necho one\nanswer=\nwhile [ -z \"$answer\" ]; do read answer || exit 5; done\necho \"two $answer\"\nexit 0\n".utf8).write(to: probe)
		try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
		let session = try connect(to: AgentService(typist: probe, probe: probe, systemFolder: directory, libraryDirectory: { throw VolumeMissing() }, shutDown: {}))
		defer { session.close() }
		var handled: [String] = []

		try session.send(.probe(.system))
		let ending = try await session.follow(within: .seconds(10)) { line in
			handled.append(line)
			if line == "one" { try session.send(line: "go") }
		}

		#expect(ending == .exit(0))
		#expect(handled == ["one", "two go"])
		#expect(session.keepAlives >= 1)
	}

	@Test func sendingAfterTheSessionEndedIsRefusedInsteadOfWritingToAReleasedDescriptor() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let replies = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {})
		try replies.fileHandleForWriting.close()
		#expect(await session.wait(within: .seconds(5)) { session.hasEnded })

		#expect(throws: AgentSession.Failure.ended) { try session.send(line: "go") }
		#expect(throws: AgentSession.Failure.ended) { try session.send(.hello) }
	}

	@Test func followingEndsAtAnAgentFailure() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let session = try connect(to: try service(typing: "exit 9") { throw VolumeMissing() })
		defer { session.close() }
		var handled: [String] = []

		try session.send(.verify(password: "power loss"))
		let ending = await session.follow(within: .seconds(10)) { handled.append($0) }

		#expect(ending == .failure("the PowerLossLibrary volume is not mounted"))
		#expect(handled.isEmpty)
	}

	@Test func followingASessionThatEndsWithoutAnEndingHandsOverEveryLineAndNoEnding() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let replies = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {})
		defer { session.close() }
		var handled: [String] = []
		try replies.fileHandleForWriting.write(contentsOf: Data("first\nlast without newline".utf8))
		try replies.fileHandleForWriting.close()

		let ending = await session.follow(within: .seconds(10)) { handled.append($0) }

		#expect(ending == nil)
		#expect(handled == ["first", "last without newline"])
	}

	@Test func followingASilentSessionGivesUpAtTheLimit() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let silent = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: silent.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {})
		defer { session.close() }

		let started = ContinuousClock.now
		let ending = await session.follow(within: .milliseconds(100)) { _ in }

		#expect(ending == nil)
		#expect(ContinuousClock.now - started < .seconds(5))
		withExtendedLifetime(silent) {}
	}

	@Test func aPeerThatWaitsToHearFromTheHarnessIsKeptAlive() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let replies = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, keepingAliveAfter: .milliseconds(50))
		defer { session.close() }
		let peerReads = requests.fileHandleForReading
		let peerWrites = replies.fileHandleForWriting
		Thread {
			try? peerWrites.write(contentsOf: Data("first\n".utf8))
			_ = try? peerReads.read(upToCount: 1)
			try? peerWrites.write(contentsOf: Data("ok\n".utf8))
		}.start()
		var handled: [String] = []

		let ending = await session.follow(within: .seconds(10)) { handled.append($0) }

		#expect(ending == .done)
		#expect(handled == ["first"])
		#expect(session.keepAlives >= 1)
	}

	@Test func aPeerThatStallsAfterEveryWindowOfSmallWritesUntilItHearsFromTheHarnessDeliversEveryLine() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		var ends: [Int32] = [-1, -1]
		try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
		let (host, peer) = (ends[0], ends[1])
		defer { close(peer) }
		let total = 40_000
		let window = 128 << 10
		let line: @Sendable (Int) -> [UInt8] = { Array("line \($0) of many small writes\n".utf8) }
		let stalls = (0 ..< total).reduce(into: (count: 0, sinceHeard: 0)) { stalls, number in
			stalls.sinceHeard += line(number).count
			if stalls.sinceHeard >= window { stalls = (stalls.count + 1, 0) }
		}.count
		Thread {
			var sinceHeard = 0
			for number in 0 ..< total {
				let bytes = line(number)
				guard bytes.withUnsafeBytes({ write(peer, $0.baseAddress, $0.count) }) == bytes.count else { return }
				sinceHeard += bytes.count
				if sinceHeard >= window {
					var byte: UInt8 = 0
					guard read(peer, &byte, 1) == 1 else { return }
					sinceHeard = 0
				}
			}
		}.start()
		let handle = FileHandle(fileDescriptor: host, closeOnDealloc: false)
		let session = AgentSession(reading: handle, writing: handle, interrupt: { shutdown(host, SHUT_RDWR) }, release: { close(host) })
		defer { session.close() }

		let delivered = await session.wait(within: .seconds(40)) { session.lines.count == total }

		#expect(delivered)
		#expect(session.lines.last == "line \(total - 1) of many small writes")
		#expect(stalls >= 9)
		#expect(session.keepAlives >= stalls)
	}

	@Test func aSilentPeerIsKeptAliveOncePerQuietPeriod() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let silent = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: silent.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, keepingAliveAfter: .milliseconds(100))
		defer { session.close() }

		_ = await session.wait(within: .milliseconds(1_050)) { false }

		#expect((5 ... 10).contains(session.keepAlives))
		#expect(requests.fileHandleForReading.availableData == Data(repeating: UInt8(ascii: "\n"), count: session.keepAlives))
		withExtendedLifetime(silent) {}
	}

	@Test func aPeerThatKeepsTalkingGetsNoKeepalive() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let replies = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, keepingAliveAfter: .seconds(1))
		defer { session.close() }
		let peerWrites = replies.fileHandleForWriting
		Thread {
			for number in 0 ..< 75 {
				try? peerWrites.write(contentsOf: Data("\(number)\n".utf8))
				usleep(20_000)
			}
		}.start()

		_ = await session.wait(within: .seconds(10)) { session.lines.count == 75 }

		#expect(session.lines.count == 75)
		#expect(session.keepAlives == 0)
	}

	@Test func everyLineIsTimedByItsArrivalSoTheLongestSilenceCanBeMeasured() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let replies = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: replies.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, keepingAliveAfter: .seconds(10))
		defer { session.close() }
		let peerWrites = replies.fileHandleForWriting
		let started = ContinuousClock.now
		Thread {
			try? peerWrites.write(contentsOf: Data("first\nsecond\n".utf8))
			usleep(300_000)
			try? peerWrites.write(contentsOf: Data("third\nfour".utf8))
			try? peerWrites.close()
		}.start()

		_ = await session.wait(within: .seconds(10)) { false }
		let ended = ContinuousClock.now

		#expect(session.lines == ["first", "second", "third", "four"])
		try #require(session.arrivals.count == 4)
		#expect(session.arrivals[0] == session.arrivals[1])
		#expect(session.arrivals[2] - session.arrivals[1] >= .milliseconds(250))
		#expect(session.longestSilence(from: started, to: ended) >= .milliseconds(250))
	}

	@Test func theLongestSilenceCountsTheQuietBeforeTheFirstLineAndAfterTheLast() {
		let start = ContinuousClock.now
		let arrivals = [-50, 10, 40, 240, 260, 900].map { start + .milliseconds($0) }

		#expect(AgentSession.longestSilence(between: arrivals, from: start, to: start + .milliseconds(300)) == .milliseconds(200))
		#expect(AgentSession.longestSilence(between: arrivals, from: start, to: start + .milliseconds(600)) == .milliseconds(340))
		#expect(AgentSession.longestSilence(between: Array(arrivals.prefix(1)), from: start, to: start + .milliseconds(70)) == .milliseconds(70))
		#expect(AgentSession.longestSilence(between: [], from: start, to: start) == .zero)
	}

	@Test func aClosedSessionSendsNoMoreKeepalives() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let silent = Pipe()
		let requests = Pipe()
		let session = AgentSession(reading: silent.fileHandleForReading, writing: requests.fileHandleForWriting, interrupt: {}, keepingAliveAfter: .milliseconds(20))
		_ = await session.wait(within: .milliseconds(100)) { false }

		session.close()
		let sent = session.keepAlives
		try? await Task.sleep(for: .milliseconds(200))

		#expect(sent >= 1)
		#expect(session.keepAlives == sent)
		withExtendedLifetime(silent) {}
	}
}
