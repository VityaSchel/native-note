import Foundation
import Testing

@testable import NativeNoteKit

private enum ForceQuit {
	struct Keystroke {
		let length: Int
		let typedAt: UInt64
	}

	static let saveWindow: UInt64 = 300_000_000
	static let writeAllowance: UInt64 = 100_000_000
	static let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
}

extension LibraryEndToEndTests {
	func typed(_ length: Int) -> String {
		String((0 ..< length).map { ForceQuit.alphabet[$0 % ForceQuit.alphabet.count] })
	}

	func typist() throws -> URL {
		let built = sequence(first: Bundle.module.bundleURL) { $0.pathComponents.count > 1 ? $0.deletingLastPathComponent() : nil }
			.map { $0.appending(path: "NativeNoteTypist") }
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
		return try #require(built, "NativeNoteTypist is built beside the test bundle")
	}

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

	@Test func aKilledSessionLosesOnlyTheLastSaveWindow() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		try AppLock.write(.fast, to: AppLock.currentFile(in: directory))
		try await NoteStore.create(url: AppLock.databaseFile(in: directory), key: workspaceKey()).close()
		var survivedTyping = 0

		for _ in 0 ..< 12 {
			let session = try await killMidTyping(in: directory, after: .milliseconds(Int.random(in: 100 ... 1_200)))

			let disk = try await observer(of: directory)
			let body = try await disk.liveNotes().first?.body ?? ""
			await disk.close()
			#expect(try await connection(to: directory).scalar("PRAGMA integrity_check") == "ok")
			#expect(body == typed(body.count))
			let durable = session.keystrokes.last { $0.typedAt + ForceQuit.saveWindow + ForceQuit.writeAllowance <= session.killedAt }?.length ?? session.start
			#expect(body.count >= durable, "lost \(durable - body.count) keystrokes typed over \(ForceQuit.saveWindow / 1_000_000) ms before the kill")
			#expect(body.count <= session.keystrokes.last?.length ?? session.start)
			survivedTyping = max(survivedTyping, body.count)
		}

		#expect(survivedTyping > 0)
	}
}
