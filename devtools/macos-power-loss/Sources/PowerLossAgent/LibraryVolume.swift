import Foundation

enum LibraryVolume {
	enum Failure: Error, CustomStringConvertible {
		case diskutil([String], Int32)
		case notMounted

		var description: String {
			switch self {
			case .diskutil(let arguments, let status): "diskutil \(arguments.joined(separator: " ")) exited with \(status)"
			case .notMounted: "the \(LibraryVolume.name) volume is not mounted"
			}
		}
	}

	static let name = "PowerLossLibrary"

	static func libraryDirectory() throws -> URL {
		if let mounted = try mountPoint() {
			return mounted.appending(path: "library")
		}
		_ = try diskutil(["mount", name])
		guard let mounted = try mountPoint() else { throw Failure.notMounted }
		return mounted.appending(path: "library")
	}

	private static func mountPoint() throws -> URL? {
		let plist = try diskutil(["info", "-plist", name])
		let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
		guard let path = info?["MountPoint"] as? String, !path.isEmpty else { return nil }
		return URL(fileURLWithPath: path)
	}

	private static func diskutil(_ arguments: [String]) throws -> Data {
		let output = Pipe()
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
		process.arguments = arguments
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		let data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else { throw Failure.diskutil(arguments, process.terminationStatus) }
		return data
	}
}
