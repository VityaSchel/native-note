import Darwin
import Foundation

public enum LocalKit {
	public static let items = ["NativeNoteTypist", "SQLCipher.framework", "power-loss-flush-probe"]
	public static let folder = URL(filePath: "/Users/Shared/NativeNotePowerLoss", directoryHint: .isDirectory)

	public static var typist: URL {
		folder.appending(path: "NativeNoteTypist")
	}

	public static var probe: URL {
		folder.appending(path: "power-loss-flush-probe")
	}

	public struct Failure: Error, CustomStringConvertible {
		public let description: String
	}

	public static func archive(_ items: [String] = items, from kit: URL) throws -> Data {
		let tar = Process()
		tar.executableURL = URL(filePath: "/usr/bin/tar")
		tar.arguments = ["--no-xattrs", "--no-mac-metadata", "-C", kit.path, "-cf", "-"] + items
		let output = Pipe()
		tar.standardOutput = output
		tar.standardError = FileHandle.nullDevice
		try tar.run()
		let archive = output.fileHandleForReading.readDataToEndOfFile()
		tar.waitUntilExit()
		guard tar.terminationStatus == 0 else {
			throw Failure(description: "tar could not pack \(items.joined(separator: ", ")) from \(kit.path)")
		}
		return archive
	}

	public static func unpack(from descriptor: Int32, byteCount: Int, into folder: URL = folder, items: [String] = items) throws {
		let files = FileManager.default
		let staging = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".new")
		try? files.removeItem(at: staging)
		try files.createDirectory(at: staging, withIntermediateDirectories: true)
		do {
			try extract(from: descriptor, byteCount: byteCount, into: staging)
			if let missing = items.first(where: { !files.fileExists(atPath: staging.appending(path: $0).path) }) {
				throw Failure(description: "the kit arrived without \(missing)")
			}
			if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
			try files.moveItem(at: staging, to: folder)
		} catch {
			try? files.removeItem(at: staging)
			throw error
		}
	}

	private static func extract(from descriptor: Int32, byteCount: Int, into staging: URL) throws {
		let tar = Process()
		tar.executableURL = URL(filePath: "/usr/bin/tar")
		tar.arguments = ["-xf", "-", "-C", staging.path]
		let input = Pipe()
		tar.standardInput = input
		tar.standardOutput = FileHandle.nullDevice
		tar.standardError = FileHandle.nullDevice
		try tar.run()
		var remaining = byteCount
		var buffer = [UInt8](repeating: 0, count: 65536)
		while remaining > 0 {
			let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, min($0.count, remaining)) }
			if count < 0, errno == EINTR { continue }
			guard count > 0 else { break }
			try input.fileHandleForWriting.write(contentsOf: buffer[..<count])
			remaining -= count
		}
		try input.fileHandleForWriting.close()
		tar.waitUntilExit()
		guard remaining == 0 else { throw Failure(description: "the kit stopped \(remaining) bytes short") }
		guard tar.terminationStatus == 0 else { throw Failure(description: "tar could not unpack the kit") }
	}
}
