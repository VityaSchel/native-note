import Foundation

nonisolated enum AppLock {
	enum Unreadable: Error, Equatable {
		case unsupportedVersion(Int)
	}

	static let directory = URL.applicationSupportDirectory

	static func databaseFile(in directory: URL) -> URL {
		directory.appending(path: "notes.db")
	}

	static func currentFile(in directory: URL) -> URL {
		directory.appending(path: "app-lock.plist")
	}

	static func pendingRekeyFile(in directory: URL) -> URL {
		directory.appending(path: "app-lock.next.plist")
	}

	static func parameterFiles(in directory: URL) -> [URL] {
		[pendingRekeyFile(in: directory), currentFile(in: directory)].filter { FileManager.default.fileExists(atPath: $0.path) }
	}

	static func keep(_ opened: URL, in directory: URL) throws {
		let pending = pendingRekeyFile(in: directory)
		if opened == pending {
			try promoteRekey(in: directory)
		} else if FileManager.default.fileExists(atPath: pending.path) {
			try FileManager.default.removeItem(at: pending)
		}
	}

	static func setAside(_ database: URL) throws {
		guard FileManager.default.fileExists(atPath: database.path) else { return }
		let aside = try asideFile(for: database)
		for suffix in ["-wal", "-shm", ""] {
			let file = URL(fileURLWithPath: database.path + suffix)
			guard FileManager.default.fileExists(atPath: file.path) else { continue }
			try FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: aside.path + suffix))
		}
	}

	static func asideFile(for database: URL) throws -> URL {
		let identity = try FileManager.default.attributesOfItem(atPath: database.path)
		let created = identity[.creationDate] as? Date ?? .now
		let number = identity[.systemFileNumber] as? Int ?? 0
		let stamp = created.formatted(.iso8601.year().month().day().dateSeparator(.omitted).time(includingFractionalSeconds: false).timeSeparator(.omitted).timeZone(separator: .omitted))
		return database.deletingLastPathComponent().appending(path: "notes-set-aside-\(stamp)-\(number).db")
	}

	static func promoteRekey(in directory: URL) throws {
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
