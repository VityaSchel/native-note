import Darwin
import Foundation

public struct AgentService: Sendable {
	public let typist: URL
	public let probe: URL
	public let kit: URL
	public let systemFolder: URL
	public let diagnosis: [DiagnosisStep]
	public let libraryDirectory: @Sendable () throws -> URL
	public let shutDown: @Sendable () -> Void

	static let longestRequest = 4096

	public init(
		typist: URL,
		probe: URL = LocalKit.probe,
		kit: URL = LocalKit.folder,
		systemFolder: URL = URL(filePath: "/private/var/tmp", directoryHint: .isDirectory),
		diagnosis: [DiagnosisStep] = GuestDiagnosis.steps,
		libraryDirectory: @escaping @Sendable () throws -> URL,
		shutDown: @escaping @Sendable () -> Void
	) {
		self.typist = typist
		self.probe = probe
		self.kit = kit
		self.systemFolder = systemFolder
		self.diagnosis = diagnosis
		self.libraryDirectory = libraryDirectory
		self.shutDown = shutDown
	}

	public func serve(input: Int32, output: Int32) {
		var enabled: Int32 = 1
		setsockopt(output, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
		let replies = ReplyChannel(descriptor: output)
		guard let line = Self.request(from: input) else { return }
		guard let request = AgentRequest(line: line) else {
			replies.send(.failure("unknown request"))
			return
		}
		do {
			switch request {
			case .hello:
				replies.send(.ready)
			case .shutdown:
				replies.send(.done)
				shutDown()
			case .install(let byteCount):
				try LocalKit.unpack(from: input, byteCount: byteCount, into: kit)
				replies.send(.done)
			case .diagnose:
				GuestDiagnosis.run(diagnosis, executing: Self.execute) { replies.send(.output($0.joined(separator: "\n"))) }
				replies.send(.done)
			case .probe(let target):
				let folder = target == .library ? try libraryDirectory().deletingLastPathComponent() : systemFolder
				let pacing = FileHandle(fileDescriptor: input, closeOnDealloc: false)
				replies.send(.exit(try relay(probe, [folder.path], input: pacing, to: replies)))
			case .prepare, .type, .verify:
				guard let (mode, password) = request.typistArguments else { return }
				let library = try libraryDirectory()
				replies.send(.exit(try relay(typist, [mode, library.path, password], input: FileHandle.nullDevice, to: replies)))
			}
		} catch {
			replies.send(.failure(String(describing: error)))
		}
	}

	static func request(from descriptor: Int32) -> String? {
		while let line = readLine(from: descriptor) {
			if !line.isEmpty { return line }
		}
		return nil
	}

	private static func readLine(from descriptor: Int32) -> String? {
		var bytes: [UInt8] = []
		var byte: UInt8 = 0
		while bytes.count < longestRequest {
			let count = read(descriptor, &byte, 1)
			if count == 1 {
				guard byte != UInt8(ascii: "\n") else { return String(decoding: bytes, as: UTF8.self) }
				bytes.append(byte)
			} else if count < 0, errno == EINTR {
				continue
			} else {
				return nil
			}
		}
		return nil
	}

	private func relay(_ executable: URL, _ arguments: [String], input: FileHandle, to replies: ReplyChannel) throws -> Int32 {
		let output = Pipe()
		let process = Process()
		process.executableURL = executable
		process.arguments = arguments
		process.standardInput = input
		process.standardOutput = output
		process.standardError = output
		try process.run()
		let descriptor = output.fileHandleForReading.fileDescriptor
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
			if count > 0 {
				replies.send(Array(buffer[..<count]))
			} else if count < 0, errno == EINTR {
				continue
			} else {
				break
			}
		}
		process.waitUntilExit()
		return process.terminationStatus
	}

	static func execute(_ command: DiagnosticCommand) -> DiagnosticRun {
		guard let executable = command.arguments.first else { return DiagnosticRun(status: nil, output: "", failure: "no command") }
		let output = Pipe()
		let process = Process()
		process.executableURL = URL(filePath: executable)
		process.arguments = Array(command.arguments.dropFirst())
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = output
		do {
			try process.run()
		} catch {
			return DiagnosticRun(status: nil, output: "", failure: String(describing: error))
		}
		let printed = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return DiagnosticRun(status: process.terminationStatus, output: String(decoding: printed, as: UTF8.self))
	}
}

private final class ReplyChannel {
	private let descriptor: Int32
	private var isBroken = false
	private var endsWithNewline = true

	init(descriptor: Int32) {
		self.descriptor = descriptor
	}

	func send(_ reply: AgentReply) {
		if !endsWithNewline { send([UInt8(ascii: "\n")]) }
		send(Array((reply.line + "\n").utf8))
	}

	func send(_ bytes: [UInt8]) {
		guard let last = bytes.last else { return }
		endsWithNewline = last == UInt8(ascii: "\n")
		var done = 0
		while !isBroken, done < bytes.count {
			let count = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + done, bytes.count - done) }
			if count > 0 {
				done += count
			} else if count < 0, errno == EINTR {
				continue
			} else {
				isBroken = true
			}
		}
	}
}
