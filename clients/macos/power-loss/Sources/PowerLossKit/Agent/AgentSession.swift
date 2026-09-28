import Darwin
import Foundation

@MainActor public final class AgentSession {
	public enum Failure: Error, Equatable, CustomStringConvertible {
		case agent(String)
		case unfinished(Duration, lastLines: [String])
		case ended

		public var description: String {
			switch self {
			case .agent(let message): "the guest agent failed: \(message)"
			case .ended: "the agent session has ended"
			case .unfinished(let timeout, let lines): "the typist did not finish within \(timeout); it last printed:\n\(lines.joined(separator: "\n"))"
			}
		}
	}

	public static let keepAliveAfter = Duration.milliseconds(250)
	private static let keepAliveLine = Data("\n".utf8)

	private let reading: FileHandle
	private let writing: FileHandle
	private let interrupt: () -> Void
	private let release: () -> Void
	private let source: any DispatchSourceRead
	private let keepAlive: any DispatchSourceTimer
	private let quietLimit: Duration
	private var lastTraffic = ContinuousClock.now
	private var unfinishedLine: [UInt8] = []
	public private(set) var lines: [String] = []
	public private(set) var arrivals: [ContinuousClock.Instant] = []
	public private(set) var hasEnded = false
	public private(set) var keepAlives = 0

	public init(reading: FileHandle, writing: FileHandle, interrupt: @escaping () -> Void, release: @escaping () -> Void = {}, keepingAliveAfter quietLimit: Duration = AgentSession.keepAliveAfter) {
		self.reading = reading
		self.writing = writing
		self.interrupt = interrupt
		self.release = release
		self.quietLimit = quietLimit
		var enabled: Int32 = 1
		setsockopt(writing.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
		source = DispatchSource.makeReadSource(fileDescriptor: reading.fileDescriptor, queue: .main)
		keepAlive = DispatchSource.makeTimerSource(queue: .main)
		source.setEventHandler { MainActor.assumeIsolated { self.receive() } }
		source.setCancelHandler { MainActor.assumeIsolated { self.end() } }
		let checkEvery = DispatchTimeInterval.nanoseconds(Int(quietLimit / .nanoseconds(1)) / 4)
		keepAlive.schedule(deadline: .now() + checkEvery, repeating: checkEvery)
		keepAlive.setEventHandler { MainActor.assumeIsolated { self.keepAliveIfQuiet() } }
		source.activate()
		keepAlive.activate()
	}

	public var replies: [AgentReply] {
		lines.map(AgentReply.init)
	}

	public var exitStatus: Int32? {
		for case .exit(let status) in replies {
			return status
		}
		return nil
	}

	public var failure: String? {
		for case .failure(let message) in replies {
			return message
		}
		return nil
	}

	public func send(_ request: AgentRequest, payload: Data = Data()) throws {
		try write(Data((request.line + "\n").utf8) + payload)
	}

	public func send(line: String) throws {
		try write(Data((line + "\n").utf8))
	}

	private func write(_ data: Data) throws {
		guard !hasEnded else { throw Failure.ended }
		lastTraffic = .now
		try writing.write(contentsOf: data)
	}

	public func follow(within timeout: Duration, _ handle: (String) throws -> Void) async rethrows -> AgentReply? {
		let deadline = ContinuousClock.now + timeout
		var handled = 0
		while true {
			let ended = hasEnded
			while handled < lines.count {
				let line = lines[handled]
				handled += 1
				switch AgentReply(line: line) {
				case .done, .exit, .failure:
					return AgentReply(line: line)
				case .ready, .output:
					try handle(line)
				}
			}
			if ended || ContinuousClock.now >= deadline { return nil }
			try? await Task.sleep(for: .milliseconds(5))
		}
	}

	public func wait(within timeout: Duration, until condition: () -> Bool) async -> Bool {
		let deadline = ContinuousClock.now + timeout
		while !condition(), !hasEnded, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(10))
		}
		return condition()
	}

	public func waitForExit(within timeout: Duration) async throws -> Int32 {
		_ = await wait(within: timeout) { exitStatus != nil || failure != nil }
		if let failure { throw Failure.agent(failure) }
		guard let exitStatus else { throw Failure.unfinished(timeout, lastLines: Array(lines.suffix(20))) }
		return exitStatus
	}

	public func longestSilence(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Duration {
		Self.longestSilence(between: arrivals, from: start, to: end)
	}

	public static func longestSilence(between arrivals: [ContinuousClock.Instant], from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Duration {
		var longest = Duration.zero
		var heard = start
		for arrival in arrivals where heard < arrival && arrival <= end {
			longest = max(longest, arrival - heard)
			heard = arrival
		}
		return max(longest, end - heard)
	}

	public func close() {
		if !hasEnded { interrupt() }
		keepAlive.cancel()
		source.cancel()
	}

	private func keepAliveIfQuiet() {
		guard !hasEnded, ContinuousClock.now - lastTraffic >= quietLimit, canWriteWithoutBlocking else { return }
		lastTraffic = .now
		guard (try? writing.write(contentsOf: Self.keepAliveLine)) != nil else { return }
		keepAlives += 1
	}

	private var canWriteWithoutBlocking: Bool {
		var check = pollfd(fd: writing.fileDescriptor, events: Int16(POLLOUT), revents: 0)
		return poll(&check, 1, 0) == 1 && check.revents == Int16(POLLOUT)
	}

	private func receive() {
		var buffer = [UInt8](repeating: 0, count: 1 << 16)
		let count = buffer.withUnsafeMutableBytes { read(reading.fileDescriptor, $0.baseAddress, $0.count) }
		guard count > 0 else {
			if count == 0 || (errno != EINTR && errno != EAGAIN) { source.cancel() }
			return
		}
		let arrival = ContinuousClock.now
		lastTraffic = arrival
		unfinishedLine += buffer[..<count]
		guard let lastNewline = unfinishedLine.lastIndex(of: UInt8(ascii: "\n")) else { return }
		let received = unfinishedLine[..<lastNewline].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Self.line)
		lines += received
		arrivals += repeatElement(arrival, count: received.count)
		unfinishedLine.removeSubrange(...lastNewline)
	}

	private func end() {
		if !unfinishedLine.isEmpty {
			lines.append(Self.line(unfinishedLine[...]))
			arrivals.append(.now)
			unfinishedLine = []
		}
		hasEnded = true
		keepAlive.cancel()
		release()
	}

	private static func line(_ bytes: ArraySlice<UInt8>) -> String {
		String(decoding: bytes.last == UInt8(ascii: "\r") ? bytes.dropLast() : bytes, as: UTF8.self)
	}
}
