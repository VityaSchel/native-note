import CryptoKit
import Darwin
import Foundation
import Testing

@testable import NativeNoteKit

/// The reference server from server/, built once per test run, each instance in its own data directory.
final class SyncServer: @unchecked Sendable {
	private static let workspace = URL(filePath: #filePath).appending(path: "../../../../../../../server").standardized

	private static let binary = Result { try build() }

	let data: URL
	private let lock = NSLock()
	private var process: Process?
	private var address: URL?

	init() throws {
		data = temporaryDirectory()
		try start()
	}

	deinit {
		kill()
		try? FileManager.default.removeItem(at: data)
	}

	var url: URL {
		lock.withLock { address ?? URL(string: "http://127.0.0.1:9/")! }
	}

	var apiKey: SymmetricKey {
		get throws {
			let text = try String(contentsOf: data.appending(path: "api-key"), encoding: .utf8)
			return try #require(EnvelopeKey.apiKey(fromHex: text))
		}
	}

	func start() throws {
		let process = Process()
		process.executableURL = try Self.binary.get()
		process.arguments = ["127.0.0.1:0", data.path]
		let stderr = Pipe()
		process.standardError = stderr
		process.standardOutput = FileHandle.nullDevice
		try process.run()
		let line = try Self.firstListeningLine(from: stderr.fileHandleForReading)
		let port = try #require(line.split(separator: ":").last.flatMap { Int($0) }, "\(line)")
		lock.withLock {
			self.process = process
			address = URL(string: "http://127.0.0.1:\(port)/")
		}
	}

	/// Ends the server at once, as a crash or a power cut would.
	func kill() {
		let running = lock.withLock {
			defer { process = nil }
			return process
		}
		guard let running, running.isRunning else { return }
		Darwin.kill(running.processIdentifier, SIGKILL)
		running.waitUntilExit()
	}

	func restart() throws {
		kill()
		try start()
	}

	private static func firstListeningLine(from handle: FileHandle) throws -> String {
		var text = ""
		while true {
			let chunk = handle.availableData
			guard !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
			text += String(decoding: chunk, as: UTF8.self)
			if let line = text.split(separator: "\n").first(where: { $0.contains("event=listening") }) {
				return String(line)
			}
		}
	}

	private static func build() throws -> URL {
		let cargo = Process()
		cargo.executableURL = URL(filePath: "/usr/bin/env")
		cargo.arguments = ["cargo", "build", "--quiet", "--locked", "-p", "native-note-server"]
		cargo.currentDirectoryURL = workspace
		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = (environment["PATH"] ?? "") + ":\(NSHomeDirectory())/.cargo/bin"
		cargo.environment = environment
		try cargo.run()
		cargo.waitUntilExit()
		guard cargo.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
		return workspace.appending(path: "target/debug/native-note-server")
	}
}

/// Posts to whatever address the server listens on now, failing or killing on command.
final class TestTransport: SyncTransport, @unchecked Sendable {
	enum Fault {
		case none
		case dropRequest
		case dropResponse
		case killServer
	}

	let server: SyncServer
	private let lock = NSLock()
	private var faults: [Fault] = []
	private(set) var posted = 0
	/// Runs while a request is in flight, as typing would.
	var whilePosting: (@MainActor () async -> Void)?

	init(_ server: SyncServer) {
		self.server = server
	}

	func failNext(_ faults: Fault...) {
		lock.withLock { self.faults += faults }
	}

	func post(_ body: Data) async throws -> Data {
		let fault = lock.withLock {
			posted += 1
			return faults.isEmpty ? .none : faults.removeFirst()
		}
		let http = HTTPTransport(url: server.url)
		await whilePosting?()
		switch fault {
		case .none:
			return try await http.post(body)
		case .dropRequest:
			throw URLError(.networkConnectionLost)
		case .dropResponse:
			_ = try await http.post(body)
			throw URLError(.networkConnectionLost)
		case .killServer:
			let posting = Task { try await http.post(body) }
			try await Task.sleep(for: .milliseconds(Int.random(in: 0 ... 3)))
			server.kill()
			let reply = await posting.result
			try server.start()
			_ = try reply.get()
			throw URLError(.networkConnectionLost)
		}
	}
}
