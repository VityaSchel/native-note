import Foundation

enum GuestKit {
	static let requiredItems = ["power-loss-agent", "NativeNoteTypist", "setup.sh", "install-agent.sh", "start-agent.sh", "dev.hloth.devtools.native-note-power-loss-test.plist"]

	static var built: URL {
		let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
		return executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "guest")
	}

	static func stage(_ layout: Layout) throws {
		let manager = FileManager.default
		let missing = requiredItems.filter { !manager.fileExists(atPath: built.appending(path: $0).path) }
		guard missing.isEmpty else {
			throw HarnessError("\(built.path) lacks \(missing.joined(separator: ", ")); build with devtools/macos-power-loss/build.sh")
		}
		try manager.createDirectory(at: layout.kit, withIntermediateDirectories: true)
		for item in try manager.contentsOfDirectory(atPath: built.path) {
			let target = layout.kit.appending(path: item)
			if manager.fileExists(atPath: target.path) {
				try manager.removeItem(at: target)
			}
			try manager.copyItem(at: built.appending(path: item), to: target)
		}
	}
}
