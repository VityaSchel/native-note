import Foundation

public struct AgentOptions: Equatable, Sendable {
	public static let usage = "usage: power-loss-agent [--kit <folder>] [--stdio]"

	public var kit: URL
	public var stdio = false

	public init(_ arguments: [String], currentDirectory: URL) throws {
		var kit: URL?
		var remaining = arguments.dropFirst().makeIterator()
		while let flag = remaining.next() {
			switch flag {
			case "--stdio":
				stdio = true
			case "--kit":
				guard let folder = remaining.next() else { throw OptionError("--kit needs a value") }
				kit = URL(filePath: folder, relativeTo: currentDirectory).absoluteURL.standardized
			default:
				throw OptionError("unknown option \(flag)")
			}
		}
		guard let kit = kit ?? Self.folder(holding: arguments.first, in: currentDirectory) else {
			throw OptionError("cannot tell which folder holds the agent; pass --kit")
		}
		self.kit = kit
	}

	private static func folder(holding executable: String?, in currentDirectory: URL) -> URL? {
		guard let executable, executable.contains("/") else { return nil }
		return URL(filePath: executable, relativeTo: currentDirectory).absoluteURL.standardized.resolvingSymlinksInPath().deletingLastPathComponent()
	}
}
