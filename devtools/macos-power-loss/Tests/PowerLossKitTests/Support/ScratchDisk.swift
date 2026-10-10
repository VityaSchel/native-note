import Foundation

@testable import PowerLossKit

func temporaryDirectory() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(path: "pl-\(UUID().uuidString.prefix(8))")
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

func stub(_ name: String, in directory: URL, _ body: String) throws {
	try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	let url = directory.appending(path: name)
	try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
	try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func original(_ offset: Int) -> UInt8 {
	UInt8(truncatingIfNeeded: offset % 251)
}

func filled(_ value: UInt8, _ count: Int) -> [UInt8] {
	[UInt8](repeating: value, count: count)
}

struct ScratchDisk {
	static let size = 64 * 1024

	let directory: URL
	let backing: URL
	let disk: OrderedDisk

	init(size: Int = Self.size) throws {
		directory = try temporaryDirectory()
		backing = directory.appending(path: "backing.img")
		try Data((0 ..< size).map(original)).write(to: backing)
		disk = try OrderedDisk(backing: backing)
	}

	var durable: [UInt8] {
		get throws { [UInt8](try Data(contentsOf: backing)) }
	}

	func remove() {
		try? FileManager.default.removeItem(at: directory)
	}
}

struct DiskModel {
	var bytes: [UInt8]

	init(size: Int = ScratchDisk.size) {
		bytes = (0 ..< size).map(original)
	}

	mutating func write(_ data: [UInt8], at offset: Int) {
		bytes.replaceSubrange(offset ..< offset + data.count, with: data)
	}
}
