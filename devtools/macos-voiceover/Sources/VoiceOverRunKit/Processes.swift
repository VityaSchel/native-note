import AppKit

public final class AppUnderTest {
	public let url: URL
	public let bundleIdentifier: String
	public private(set) var running: NSRunningApplication?

	public init(url: URL) throws {
		guard let identifier = Bundle(url: url)?.bundleIdentifier else { throw RunError("no bundle at \(url.path)") }
		self.url = url
		bundleIdentifier = identifier
	}

	public var pid: pid_t? { running?.processIdentifier }

	public func launch() throws {
		let open = try Process.run(URL(filePath: "/usr/bin/open"), arguments: ["-n", "-F", url.path])
		open.waitUntilExit()
		let deadline = Date.now.addingTimeInterval(20)
		while Date.now < deadline {
			if let launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first(where: { $0.isFinishedLaunching }) {
				running = launched
				activate()
				return
			}
			Clock.pause(0.1)
		}
		throw RunError("\(url.lastPathComponent) did not launch")
	}

	public var isFrontmost: Bool {
		NSWorkspace.shared.frontmostApplication?.processIdentifier == running?.processIdentifier
	}

	public func activate() {
		running?.activate()
		let deadline = Date.now.addingTimeInterval(3)
		while !isFrontmost, Date.now < deadline { Clock.pause(0.1) }
		Clock.pause(0.2)
	}

	public func quit() {
		for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
			app.terminate()
			let deadline = Date.now.addingTimeInterval(10)
			while !app.isTerminated, Date.now < deadline { Clock.pause(0.1) }
			if !app.isTerminated { app.forceTerminate() }
		}
		running = nil
	}
}

public final class SyncServer {
	public let url: URL
	public let apiKey: String
	private let process: Process

	public init(binary: URL, data: URL, port: Int) throws {
		try? FileManager.default.removeItem(at: data)
		try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
		let process = Process()
		process.executableURL = binary
		process.arguments = ["127.0.0.1:\(port)", data.path]
		let log = data.appending(path: "server.log")
		FileManager.default.createFile(atPath: log.path, contents: nil)
		let handle = try FileHandle(forWritingTo: log)
		process.standardOutput = handle
		process.standardError = handle
		try process.run()
		self.process = process
		let deadline = Date.now.addingTimeInterval(15)
		while Date.now < deadline, !((try? String(contentsOf: log, encoding: .utf8))?.contains("event=listening") ?? false) {
			guard process.isRunning else { throw RunError("the sync server exited: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")") }
			Clock.pause(0.1)
		}
		guard let key = try? String(contentsOf: data.appending(path: "api-key"), encoding: .utf8) else {
			process.terminate()
			throw RunError("the sync server wrote no api-key in \(data.path)")
		}
		apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
		url = URL(string: "http://127.0.0.1:\(port)")!
	}

	public func stop() {
		process.terminate()
		process.waitUntilExit()
	}
}

public struct RunError: Error, CustomStringConvertible {
	public let description: String

	public init(_ description: String) {
		self.description = description
	}
}
