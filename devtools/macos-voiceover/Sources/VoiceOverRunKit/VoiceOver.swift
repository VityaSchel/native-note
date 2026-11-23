import AppKit

public enum VoiceOverError: Error, CustomStringConvertible {
	case script(String, String)
	case notStarted

	public var description: String {
		switch self {
		case let .script(source, error): "AppleScript failed: \(source)\n\(error)"
		case .notStarted: "VoiceOver did not start; check that VoiceOver Utility allows AppleScript control"
		}
	}
}

public final class VoiceOver {
	public enum Direction: String {
		case left, right, up, down
		case into = "into item"
		case outOf = "out of item"
	}

	private static let bundleIdentifier = "com.apple.VoiceOver"
	private var compiled: [String: NSAppleScript] = [:]

	public init() {}

	public var isRunning: Bool {
		!NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
	}

	public func start() throws {
		if !isRunning {
			try Process.run(URL(filePath: "/usr/bin/open"), arguments: ["/System/Library/CoreServices/VoiceOver.app"]).waitUntilExit()
		}
		let deadline = Date.now.addingTimeInterval(30)
		var failure: Error?
		while Date.now < deadline {
			if isRunning {
				do {
					try say("Native Note VoiceOver run")
					return
				} catch {
					failure = error
				}
			}
			Clock.pause(0.25)
		}
		throw failure ?? VoiceOverError.notStarted
	}

	public func quit() {
		_ = try? tell("quit")
		let deadline = Date.now.addingTimeInterval(10)
		while isRunning, Date.now < deadline { Clock.pause(0.25) }
	}

	public func lastPhrase() throws -> String {
		try tell("return content of last phrase")
	}

	public func textUnderCursor() throws -> String {
		try tell("return text under cursor of vo cursor")
	}

	public func move(_ direction: Direction) throws {
		try tell("tell vo cursor to move \(direction.rawValue)")
	}

	public func performAction() throws {
		try tell("tell vo cursor to perform action")
	}

	public func say(_ text: String) throws {
		try tell("output \"\(text.replacing("\"", with: "'"))\"")
	}

	@discardableResult
	public func tell(_ command: String) throws -> String {
		let source = "tell application \"VoiceOver\" to \(command)"
		let script = compiled[source] ?? NSAppleScript(source: source)!
		compiled[source] = script
		var error: NSDictionary?
		let result = script.executeAndReturnError(&error)
		if let error {
			compiled[source] = nil
			throw VoiceOverError.script(source, error.description)
		}
		return result.stringValue ?? ""
	}
}

public enum Clock {
	public static func pause(_ seconds: TimeInterval) {
		RunLoop.main.run(until: Date.now.addingTimeInterval(seconds))
	}
}
