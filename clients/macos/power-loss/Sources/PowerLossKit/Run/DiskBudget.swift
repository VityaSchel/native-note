import Darwin
import Foundation

public enum DiskBudget {
	public struct Exceeded: Error, Equatable, CustomStringConvertible {
		public let description: String
	}

	public static let reserve: Int64 = 40 << 30
	public static let cap: Int64 = 45_000_000_000
	public static let installGrowth: Int64 = 30 << 30

	public static func allows(allocating bytes: Int64, free: Int64) -> Bool {
		free - bytes >= reserve
	}

	public static func check(free: Int64, allocated: Int64) throws {
		guard free >= reserve else {
			throw Exceeded(description: "only \(free >> 30) GiB are free, and the harness keeps \(reserve >> 30) GiB free")
		}
		guard allocated <= cap else {
			throw Exceeded(description: "the VM files take \(allocated / 1_000_000_000) GB, over the \(cap / 1_000_000_000) GB the harness allows")
		}
	}

	public static func check(_ home: URL) throws {
		try check(free: freeBytes(at: home), allocated: allocatedBytes(in: home))
	}

	public static func freeBytes(at url: URL) throws -> Int64 {
		var status = statfs()
		guard statfs(url.path, &status) == 0 else { throw DiskError.io(errno: errno) }
		return Int64(status.f_bavail) * Int64(status.f_bsize)
	}

	public static func allocatedBytes(in directory: URL) throws -> Int64 {
		let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
		guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { return 0 }
		var total: Int64 = 0
		for case let file as URL in files where file.pathExtension != "ipsw" {
			let values = try file.resourceValues(forKeys: keys)
			guard values.isRegularFile == true else { continue }
			total += Int64(values.totalFileAllocatedSize ?? 0)
		}
		return total
	}
}
