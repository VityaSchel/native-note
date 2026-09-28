import Foundation
import PowerLossKit

extension NBDTransport {
	var endpoint: NBDServer.Endpoint {
		switch self {
		case .unix: .unixSocket(path: URL.temporaryDirectory.appending(path: "power-loss-\(getpid()).sock").path)
		case .tcp: .loopback(port: 0)
		}
	}
}

struct PowerLossRun {
	private struct Typing {
		let beforeCut: TypingLog
		let afterStop: TypingLog
		let activity: DiskActivity
		let keepAlivesWhileTyping: Int
		let longestSilenceWhileTyping: Duration
		let stoppedEarly: String?
	}

	static let password = "power loss"
	static let bootTimeout = Duration.seconds(600)
	static let runningAfterCut = Duration.milliseconds(500) ... Duration.seconds(2)

	let layout: Layout
	let options: RunOptions

	func run() async throws -> Bool {
		guard options.library != .image else { throw HarnessError("--library image cannot lose power; use it with power-loss diagnose") }
		try layout.requireSetUp()
		try GuestKit.stage(layout)
		let link = try agentLink()
		try FileManager.default.createDirectory(at: layout.results, withIntermediateDirectories: true)
		let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted).timeZone(separator: .omitted))
		let results = layout.results.appending(path: "\(stamp).jsonl")
		guard FileManager.default.createFile(atPath: results.path, contents: nil) else { throw HarnessError("cannot create \(results.path)") }
		let output = try FileHandle(forWritingTo: results)
		defer { try? output.close() }

		let typist = options.control.map { "the \($0.rawValue) control typist" } ?? "the typist"
		say("power-loss: seed \(options.seed), \(options.count) runs of \(typist), tearing \(options.tearing ? "on" : "off"), library on \(options.library.rawValue), agent over \(link)")
		try await prepareLibrary(link)
		var records: [RunRecord] = []
		for planned in RunPlan.make(seed: options.seed, count: options.count, tearing: options.tearing) {
			var record = RunRecord(seed: options.seed, run: planned, control: options.control, date: .now)
			var harnessFailure: Error?
			do {
				try await scenario(planned, link: link, into: &record)
			} catch {
				record.verdict = Verdict(problems: ["harness: \(error)"])
				harnessFailure = error
			}
			try output.write(contentsOf: Data((record.jsonLine + "\n").utf8))
			records.append(record)
			say(record.summary)
			if let harnessFailure { throw harnessFailure }
		}
		let summary = RunSummary(records, control: options.control)
		say("power-loss: \(summary.line). Results: \(results.path)")
		return summary.succeeded
	}

	private func agentLink() throws -> AgentLink {
		try AgentLink(options.transport ?? layout.savedTransport() ?? .vsock, layout: layout)
	}

	private func boot<T>(_ nbd: URL, _ body: (Machine) async throws -> T) async throws -> T {
		try DiskBudget.check(layout.home)
		return try await Machine.running(try MachineConfiguration.make(layout, role: .run(library: .nbd(nbd, options.library), kit: layout.kit)), body)
	}

	private func startServer(on library: URL) throws -> (NBDServer, URL) {
		let server = NBDServer(disk: try OrderedDisk(backing: library), log: say)
		return (server, try server.start(options.nbd.endpoint))
	}

	private func prepareLibrary(_ link: AgentLink) async throws {
		say("prepare: setting up the library on the formatted disk")
		try BackingFile.restore(layout.library, from: layout.formattedLibrary)
		let (server, nbd) = try startServer(on: layout.library)
		defer { server.stop() }
		try await boot(nbd) { machine in
			try await link.waitUntilReady(on: machine, within: Self.bootTimeout)
			try await link.pushKit(layout, on: machine)
			let session = try await link.open(.prepare(password: Self.password), on: machine)
			defer { session.close() }
			let status = try await session.waitForExit(within: .seconds(600))
			guard status == 0, session.lines.contains("prepared 1") else {
				throw HarnessError("preparing the library exited with \(status):\n\(session.lines.joined(separator: "\n"))")
			}
			await link.shutDown(machine)
		}
		server.stop()
		try BackingFile.restore(layout.preparedLibrary, from: layout.library)
	}

	private func scenario(_ planned: PlannedRun, link: AgentLink, into record: inout RunRecord) async throws {
		try BackingFile.restore(layout.library, from: layout.preparedLibrary)
		let (server, nbd) = try startServer(on: layout.library)
		defer { server.stop() }

		let tearing = planned.tearSeed.map { "tearing the first change after the cut with seed \($0)" } ?? "tearing nothing"
		say("run \(planned.number): typing, cutting \(planned.cutAfterMilliseconds) ms after the typist starts, \(tearing)")
		let typing = try await boot(nbd) { machine in
			try await link.waitUntilReady(on: machine, within: Self.bootTimeout)
			let session = try await link.open(.type(password: Self.password, control: options.control), on: machine)
			defer { session.close() }
			guard await session.wait(within: .seconds(300), until: { TypingLog(session.lines).start != nil }) else {
				throw HarnessError("the typist did not start: \(session.failure ?? session.lines.suffix(5).joined(separator: " | "))")
			}
			let atStart = (activity: server.activity, keepAlives: session.keepAlives, instant: ContinuousClock.now)
			try await Task.sleep(for: .milliseconds(planned.cutAfterMilliseconds))
			let stoppedEarly = Self.stop(of: session)
			let beforeCut = TypingLog(session.lines)
			server.cutPower(tearingWith: planned.tearSeed)
			let silence = session.longestSilence(from: atStart.instant, to: .now)
			let activity = server.activity.since(atStart.activity)
			let keepAlives = session.keepAlives - atStart.keepAlives
			await Self.waitAfterCut(on: server, tearing: planned.tearSeed != nil)
			server.disconnect()
			await machine.powerOff()
			_ = await session.wait(within: .seconds(3)) { false }
			return Typing(beforeCut: beforeCut, afterStop: TypingLog(session.lines), activity: activity, keepAlivesWhileTyping: keepAlives, longestSilenceWhileTyping: silence, stoppedEarly: stoppedEarly)
		}
		record.typed = typing.afterStop.typed
		record.typedAfterCut = typing.afterStop.typed - typing.beforeCut.typed
		record.acknowledgements = typing.afterStop.acknowledgements.count
		record.acknowledgedAfterCut = typing.afterStop.acknowledgements.count - typing.beforeCut.acknowledgements.count
		record.acknowledged = typing.afterStop.acknowledged
		record.activity = typing.activity
		record.keepAlivesWhileTyping = typing.keepAlivesWhileTyping
		record.longestSilenceWhileTyping = typing.longestSilenceWhileTyping.milliseconds
		record.longestKeystrokePauseWhileTyping = typing.beforeCut.longestPauseBetweenKeystrokes.milliseconds
		record.unexpectedOutput = Array(typing.afterStop.unexpected.prefix(20))
		try server.restorePower()
		let cut = server.cut
		record.cut = cut

		say("run \(planned.number): verifying after the cut dropped \(cut.dropped.summary)")
		let verification = try await boot(nbd) { machine in
			try await link.waitUntilReady(on: machine, within: Self.bootTimeout)
			let session = try await link.open(.verify(password: Self.password), on: machine)
			defer { session.close() }
			_ = await session.wait(within: .seconds(300)) { session.exitStatus != nil || session.failure != nil }
			let verification = Verification(lines: session.lines, exitStatus: session.exitStatus, failure: session.failure)
			await link.shutDown(machine)
			return verification
		}
		if case .report(let report) = verification {
			record.disk = NoteOnDisk(report)
		}
		let verdict = verification.verdict(typing: typing.afterStop, beforeCut: typing.beforeCut)
		record.verdict = verdict.adding([typing.stoppedEarly].compactMap(\.self))
	}

	private static func waitAfterCut(on server: NBDServer, tearing: Bool) async {
		let cut = ContinuousClock.now
		while ContinuousClock.now - cut < runningAfterCut.upperBound {
			let waitedLongEnough = ContinuousClock.now - cut >= runningAfterCut.lowerBound
			if waitedLongEnough, !tearing || server.disk.tornWrite != nil { return }
			try? await Task.sleep(for: .milliseconds(5))
		}
	}

	private static func stop(of session: AgentSession) -> String? {
		if let failure = session.failure { return "the agent failed before the cut: \(failure)" }
		if let status = session.exitStatus { return "the typist exited with \(status) before the cut" }
		return session.hasEnded ? "the agent connection closed before the cut" : nil
	}
}
