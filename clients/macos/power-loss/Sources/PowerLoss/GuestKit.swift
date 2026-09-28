import Foundation

enum GuestKit {
	static let requiredItems = ["power-loss-agent", "power-loss-flush-probe", "NativeNoteTypist", "SQLCipher.framework", "setup.sh", "allow-agent.sh", "install-agent.sh", "start-agent.sh", "dev.hloth.nativenote.power-loss-agent.plist"]

	static var built: URL {
		let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
		return executable.resolvingSymlinksInPath().deletingLastPathComponent().appending(path: "guest")
	}

	static func stage(_ layout: Layout) throws {
		let manager = FileManager.default
		let missing = requiredItems.filter { !manager.fileExists(atPath: built.appending(path: $0).path) }
		guard missing.isEmpty else {
			throw HarnessError("\(built.path) lacks \(missing.joined(separator: ", ")); build with clients/macos/power-loss/build.sh")
		}
		try manager.createDirectory(at: layout.kit, withIntermediateDirectories: true)
		for item in try manager.contentsOfDirectory(atPath: built.path) {
			let target = layout.kit.appending(path: item)
			if manager.fileExists(atPath: target.path) {
				try manager.removeItem(at: target)
			}
			try manager.copyItem(at: built.appending(path: item), to: target)
		}
		try stageSSHKey(layout)
	}

	private static func stageSSHKey(_ layout: Layout) throws {
		let publicKey = URL(fileURLWithPath: layout.sshKey.path + ".pub")
		if !layout.exists(layout.sshKey) {
			let keygen = Process()
			keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
			keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "native-note-power-loss", "-f", layout.sshKey.path]
			try keygen.run()
			keygen.waitUntilExit()
			guard keygen.terminationStatus == 0 else { throw HarnessError("ssh-keygen exited with \(keygen.terminationStatus)") }
		}
		let staged = layout.kit.appending(path: "power-loss.pub")
		if layout.exists(staged) {
			try FileManager.default.removeItem(at: staged)
		}
		try FileManager.default.copyItem(at: publicKey, to: staged)
	}
}
