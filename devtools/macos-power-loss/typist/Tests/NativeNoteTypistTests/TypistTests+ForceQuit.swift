import Foundation
import PowerLossKit
import Testing

@testable import NativeNoteKit

private enum ForceQuit {
	struct Keystroke {
		let length: Int
		let typedAt: UInt64
	}

	static let saveWindow: UInt64 = 300_000_000
	static let writeAllowance: UInt64 = 100_000_000
}

extension TypistTests {
	private func killMidTyping(in directory: URL, after typing: Duration) async throws -> (start: Int, keystrokes: [ForceQuit.Keystroke], killedAt: UInt64) {
		let output = Pipe()
		let process = Process()
		process.executableURL = try typist()
		process.arguments = ["type", directory.path, workspacePassword]
		process.standardOutput = output
		let exited = AsyncStream<Void> { continuation in
			process.terminationHandler = { _ in continuation.finish() }
		}
		try process.run()
		defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }

		var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
		let first = try await lines.next()
		let start = try #require(first.flatMap { $0.hasPrefix("start ") ? Int($0.dropFirst(6)) : nil }, "\(first ?? "no output")")
		try await Task.sleep(for: typing)
		let killedAt = DispatchTime.now().uptimeNanoseconds
		try #require(process.isRunning, "the typist exited before the kill")
		kill(process.processIdentifier, SIGKILL)
		for await _ in exited {}

		var keystrokes: [ForceQuit.Keystroke] = []
		while let line = try await lines.next() {
			let fields = line.split(separator: " ")
			guard fields.count == 2, let length = Int(fields[0]), let typedAt = UInt64(fields[1]) else { continue }
			keystrokes.append(ForceQuit.Keystroke(length: length, typedAt: typedAt))
		}
		return (start, keystrokes, killedAt)
	}

	@Test(arguments: [UInt64(0xf0_0002)])
	func aKilledSessionLosesOnlyTheLastSaveWindow(seed: UInt64) async throws {
		let directory = temporaryDirectory()
		try await makeLibrary(in: directory)
		var random = SeededGenerator(seed: seed)
		var survivedTyping = 0

		for _ in 0 ..< 12 {
			let session = try await killMidTyping(in: directory, after: .milliseconds(Int.random(in: 100 ... 1_200, using: &random)))

			let disk = try await observer(of: directory)
			let body = try await disk.liveNotes().first?.body ?? ""
			await disk.close()
			#expect(try await connection(to: directory).scalar("PRAGMA integrity_check") == "ok")
			#expect(body == TypedStream.text(length: body.count))
			let durable = session.keystrokes.last { $0.typedAt + ForceQuit.saveWindow + ForceQuit.writeAllowance <= session.killedAt }?.length ?? session.start
			#expect(body.count >= durable, "lost \(durable - body.count) keystrokes typed over \(ForceQuit.saveWindow / 1_000_000) ms before the kill")
			#expect(body.count <= session.keystrokes.last?.length ?? session.start)
			survivedTyping = max(survivedTyping, body.count)
		}

		#expect(survivedTyping > 0)
	}
}
