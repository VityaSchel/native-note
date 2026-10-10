import Darwin
import Foundation

public enum FlushProbe {
	public static let chunk = 64 << 10
	public static let usage = "usage: power-loss-flush-probe <folder on the volume to probe>"

	private struct Call {
		let name: String
		let perform: (Int32) -> Int
	}

	public static func run(in folder: URL, emit: (String) -> Void, pace: () -> Void) -> Int32 {
		let file = folder.appending(path: ".power-loss-flush-probe-\(getpid())")
		let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
		guard descriptor >= 0 else {
			emit("probe: cannot create \(file.path): errno \(errno)")
			return 1
		}
		defer {
			close(descriptor)
			unlink(file.path)
		}
		emit("probe: file \(file.path) on \(volume(of: descriptor))")
		let first = [UInt8](repeating: 0xA5, count: chunk)
		let second = [UInt8](repeating: 0x5A, count: chunk)
		let calls = [
			Call(name: "write \(chunk) bytes at 0") { descriptor in first.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) } },
			Call(name: "fsync") { Int(fsync($0)) },
			Call(name: "fcntl F_FULLFSYNC") { Int(fcntl($0, F_FULLFSYNC)) },
			Call(name: "fcntl F_BARRIERFSYNC") { Int(fcntl($0, F_BARRIERFSYNC)) },
			Call(name: "write \(chunk) bytes at \(chunk)") { descriptor in second.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(chunk)) } },
			Call(name: "fcntl F_FULLFSYNC") { Int(fcntl($0, F_FULLFSYNC)) },
		]
		var failed = false
		for (index, call) in calls.enumerated() {
			emit(ProbeMarker.before(step: index + 1, call: call.name).line)
			pace()
			let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
			errno = 0
			let result = call.perform(descriptor)
			let error = errno
			let elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000
			emit(ProbeMarker.after(step: index + 1, call: call.name, result: result, errno: error, microseconds: elapsed).line)
			pace()
			failed = failed || result < 0
		}
		emit("probe: done")
		return failed ? 1 : 0
	}

	public static func awaitGo(reading next: () -> String?) {
		while let line = next(), line.isEmpty {}
	}

	private static func volume(of descriptor: Int32) -> String {
		var status = statfs()
		guard fstatfs(descriptor, &status) == 0 else { return "an unknown volume (fstatfs errno \(errno))" }
		let device = withUnsafeBytes(of: status.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		let mountPoint = withUnsafeBytes(of: status.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		let type = withUnsafeBytes(of: status.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
		return "\(device) mounted at \(mountPoint) (\(type))"
	}
}
