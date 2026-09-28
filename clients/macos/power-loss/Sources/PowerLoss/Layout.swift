import Foundation
import PowerLossKit

struct Layout {
	static let standard = Layout(home: URL.applicationSupportDirectory.appending(path: "NativeNotePowerLoss"))

	static let bootDiskSize = 48 << 30
	static let librarySize = 2 << 30

	let home: URL

	var bundle: URL { home.appending(path: "vm") }
	var results: URL { home.appending(path: "results") }
	var hardwareModel: URL { bundle.appending(path: "hardware-model") }
	var machineIdentifier: URL { bundle.appending(path: "machine-identifier") }
	var auxiliaryStorage: URL { bundle.appending(path: "auxiliary-storage") }
	var bootDisk: URL { bundle.appending(path: "disk.img") }
	var library: URL { bundle.appending(path: "library.img") }
	var formattedLibrary: URL { bundle.appending(path: "library-formatted.img") }
	var preparedLibrary: URL { bundle.appending(path: "library-prepared.img") }
	var installed: URL { bundle.appending(path: "installed") }
	var sshKey: URL { bundle.appending(path: "ssh-key") }
	var kit: URL { bundle.appending(path: "kit") }
	var setupFinished: URL { kit.appending(path: "setup-finished") }
	var agentTransport: URL { bundle.appending(path: "agent-transport") }

	func exists(_ url: URL) -> Bool {
		FileManager.default.fileExists(atPath: url.path)
	}

	func restoreImage() throws -> URL {
		let images = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ipsw" }
		guard images.count == 1, let image = images.first else {
			throw HarnessError("expected one .ipsw file in \(home.path), found \(images.count)")
		}
		return image
	}

	func requireInstalled() throws {
		guard exists(installed) else { throw HarnessError("no installed VM in \(bundle.path); run power-loss install first") }
	}

	func requireSetUp() throws {
		try requireInstalled()
		guard exists(formattedLibrary) else { throw HarnessError("the VM is not set up; run power-loss setup first") }
	}

	func setUpAccount() throws -> String {
		let account = String(decoding: try Data(contentsOf: setupFinished), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !account.isEmpty else { throw HarnessError("\(setupFinished.path) names no account") }
		return account
	}

	func savedTransport() -> AgentTransport? {
		(try? String(contentsOf: agentTransport, encoding: .utf8)).flatMap { AgentTransport(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
	}
}

struct HarnessError: Error, CustomStringConvertible {
	let description: String

	init(_ description: String) {
		self.description = description
	}
}

nonisolated func say(_ line: String) {
	FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
