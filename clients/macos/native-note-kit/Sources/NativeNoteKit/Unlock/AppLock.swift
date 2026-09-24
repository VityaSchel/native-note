import Foundation

nonisolated enum AppLock {
	enum Unreadable: Error, Equatable {
		case unsupportedVersion(Int)
	}

	static let directory = URL.applicationSupportDirectory

	static func database(in directory: URL = directory) -> URL {
		directory.appending(path: "notes.db")
	}

	static func currentFile(in directory: URL = directory) -> URL {
		directory.appending(path: "app-lock.plist")
	}

	static func pendingRekeyFile(in directory: URL = directory) -> URL {
		directory.appending(path: "app-lock.next.plist")
	}

	static func candidates(in directory: URL = directory) -> [UnlockParameters] {
		[pendingRekeyFile(in: directory), currentFile(in: directory)].compactMap { try? read(from: $0) }
	}

	static func promoteRekey(in directory: URL = directory) throws {
		try Data(contentsOf: pendingRekeyFile(in: directory)).write(to: currentFile(in: directory), options: .atomic)
		try FileManager.default.setAttributes(
			[.posixPermissions: 0o600],
			ofItemAtPath: currentFile(in: directory).path
		)
		try FileManager.default.removeItem(at: pendingRekeyFile(in: directory))
	}

	static func read(from url: URL) throws -> UnlockParameters {
		let parameters = try PropertyListDecoder().decode(UnlockParameters.self, from: Data(contentsOf: url))
		guard parameters.version == UnlockParameters.currentVersion else {
			throw Unreadable.unsupportedVersion(parameters.version)
		}
		return parameters
	}

	static func write(_ parameters: UnlockParameters, to url: URL) throws {
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true,
			attributes: [.posixPermissions: 0o700]
		)
		try encoder.encode(parameters).write(to: url, options: .atomic)
		try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
	}
}
