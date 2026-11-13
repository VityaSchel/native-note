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

	static func erase(in directory: URL) throws {
		let database = databaseFile(in: directory)
		let setAside = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
			.filter { $0.hasPrefix("notes-set-aside-") }
			.map { directory.appending(path: $0) } ?? []
		let files = [pendingRekeyFile(in: directory), currentFile(in: directory)]
			+ ["", "-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
			+ setAside
		for file in files where FileManager.default.fileExists(atPath: file.path) {
			try FileManager.default.removeItem(at: file)
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

	static func promoteRekey(in directory: URL, sync: (Int32) throws -> Void = fullSync) throws {
		try durablyReplace(currentFile(in: directory), with: Data(contentsOf: pendingRekeyFile(in: directory)), sync: sync)
		try FileManager.default.removeItem(at: pendingRekeyFile(in: directory))
	}

	static func promoteRekey(to parameters: UnlockParameters, in directory: URL, sync: (Int32) throws -> Void = fullSync) throws {
		try write(parameters, to: currentFile(in: directory), sync: sync)
		let pending = pendingRekeyFile(in: directory)
		if FileManager.default.fileExists(atPath: pending.path) { try FileManager.default.removeItem(at: pending) }
	}

	static func read(from url: URL) throws -> UnlockParameters {
		let parameters = try PropertyListDecoder().decode(UnlockParameters.self, from: Data(contentsOf: url))
		guard parameters.version == UnlockParameters.currentVersion else {
			throw Unreadable.unsupportedVersion(parameters.version)
		}
		return parameters
	}

	static func write(_ parameters: UnlockParameters, to url: URL, sync: (Int32) throws -> Void = fullSync) throws {
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		try durablyReplace(url, with: encoder.encode(parameters), sync: sync)
	}

	static func durablyReplace(_ url: URL, with data: Data, sync: (Int32) throws -> Void = fullSync) throws {
		let directory = url.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
		let file = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
		guard file >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
		do {
			defer { close(file) }
			try data.withUnsafeBytes { bytes in
				guard let base = bytes.baseAddress else { return }
				var written = 0
				while written < bytes.count {
					let count = Foundation.write(file, base + written, bytes.count - written)
					guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
					written += count
				}
			}
			try sync(file)
		} catch {
			unlink(temporary.path)
			throw error
		}
		guard rename(temporary.path, url.path) == 0 else {
			let error = POSIXError(.init(rawValue: errno) ?? .EIO)
			unlink(temporary.path)
			throw error
		}
		let folder = open(directory.path, O_RDONLY | O_CLOEXEC)
		guard folder >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
		defer { close(folder) }
		try sync(folder)
	}

	static func fullSync(_ descriptor: Int32) throws {
		guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
	}
}
