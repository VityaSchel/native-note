import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import NativeNoteKit

struct SyncServerUnavailable: Error, CustomStringConvertible {
	let description: String
}

struct BuildsSyncServer: SuiteTrait, TestTrait, TestScoping {
	final class Started: Sendable {
		private let servers = Mutex<[SyncServer]>([])

		func add(_ server: SyncServer) {
			servers.withLock { $0.append(server) }
		}

		func killAll() {
			for server in servers.withLock({ $0 }) {
				server.kill()
			}
		}
	}

	@TaskLocal static var started: Started?

	var isRecursive: Bool { true }

	func prepare(for test: Test) async throws {
		try SyncServer.build()
	}

	func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
		guard testCase != nil else { return try await function() }
		let started = Started()
		defer { started.killAll() }
		try await Self.$started.withValue(started) { try await function() }
	}
}

extension Trait where Self == BuildsSyncServer {
	static var syncServer: Self { BuildsSyncServer() }
}

final class SyncServer: @unchecked Sendable {
	static let buildLimit = Duration.seconds(900)

	static let buildLog = URL.temporaryDirectory.appending(path: "native-note-server-build-\(UUID().uuidString).log")

	private static let workspace = URL(filePath: #filePath).appending(path: "../../../../../../../server").standardized

	private static let built = Result { try cargoBuild() }

	private static let wasBuiltBeforeTheTests = Mutex(false)

	let data: URL
	private let lock = NSLock()
	private var process: Process?
	private var address: URL?

	init() throws {
		data = temporaryDirectory()
		BuildsSyncServer.started?.add(self)
		try start()
	}

	deinit {
		kill()
	}

	var isRunning: Bool {
		lock.withLock { process?.isRunning == true }
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

	static func build() throws {
		_ = try built.get()
		wasBuiltBeforeTheTests.withLock { $0 = true }
	}

	func start() throws {
		guard Self.wasBuiltBeforeTheTests.withLock({ $0 }) else {
			throw SyncServerUnavailable(description: "A test that starts the sync server needs the .syncServer trait, which builds it before any test's time limit starts.")
		}
		let process = Process()
		process.executableURL = try Self.built.get()
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
			guard !chunk.isEmpty else {
				throw SyncServerUnavailable(description: "The sync server exited before it listened: \(text.isEmpty ? "it printed nothing" : text)")
			}
			text += String(decoding: chunk, as: UTF8.self)
			if let line = text.split(separator: "\n").first(where: { $0.contains("event=listening") }) {
				return String(line)
			}
		}
	}

	private static func cargoBuild() throws -> URL {
		let command = "cargo build --quiet --locked -p native-note-server"
		FileManager.default.createFile(atPath: buildLog.path, contents: nil)
		defer { try? FileManager.default.removeItem(at: buildLog) }
		let cargo = Process()
		cargo.executableURL = URL(filePath: "/usr/bin/env")
		cargo.arguments = command.split(separator: " ").map(String.init)
		cargo.currentDirectoryURL = workspace
		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = (environment["PATH"] ?? "") + ":\(NSHomeDirectory())/.cargo/bin"
		cargo.environment = environment
		cargo.standardError = try FileHandle(forWritingTo: buildLog)
		let exited = DispatchSemaphore(value: 0)
		cargo.terminationHandler = { _ in exited.signal() }
		do {
			try cargo.run()
		} catch {
			throw SyncServerUnavailable(description: "The sync server was not built: `\(command)` could not start in \(workspace.path): \(error.localizedDescription)")
		}
		guard exited.wait(timeout: .now() + .seconds(Int(buildLimit.components.seconds))) == .success else {
			cargo.terminate()
			throw SyncServerUnavailable(description: "The sync server was not built: `\(command)` in \(workspace.path) did not finish within \(buildLimit).")
		}
		guard cargo.terminationStatus == 0 else {
			let output = (try? String(contentsOf: buildLog, encoding: .utf8)) ?? ""
			let lastLines = output.split(separator: "\n").suffix(30).joined(separator: "\n")
			throw SyncServerUnavailable(description: "The sync server was not built: `\(command)` in \(workspace.path) exited with status \(cargo.terminationStatus).\n\(lastLines)")
		}
		return workspace.appending(path: "target/debug/native-note-server")
	}
}

final class TestTransport: SyncTransport, @unchecked Sendable {
	enum Fault {
		case none
		case dropRequest
		case dropResponse
		case killServer(after: Duration)
		case replyReplaced
	}

	let server: SyncServer
	private let lock = NSLock()
	private var faults: [Fault] = []
	private(set) var posted = 0
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
		case .replyReplaced:
			_ = try await http.post(body)
			throw SyncError.refused(status: 502)
		case let .killServer(delay):
			let posting = Task { try await http.post(body) }
			try await Task.sleep(for: delay)
			server.kill()
			let reply = await posting.result
			try server.start()
			_ = try reply.get()
			throw URLError(.networkConnectionLost)
		}
	}
}
