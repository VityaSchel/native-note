import Darwin
import Foundation
import Testing

@testable import PowerLossKit

@Suite(.timeLimit(.minutes(1)))
struct NBDServerTests {
	private let scratch: ScratchDisk
	private let server: NBDServer

	init() throws {
		scratch = try ScratchDisk()
		server = NBDServer(disk: scratch.disk)
	}

	private func finish() {
		server.stop()
		scratch.remove()
	}

	private func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
		return withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
	}

	private func connectUnixSocket(_ path: String) throws -> NBDTestClient {
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		let connected = withUnixAddress(path) { Darwin.connect(descriptor, $0, $1) }
		let client = NBDTestClient(descriptor: descriptor)
		try #require(connected == 0, "connect failed with errno \(errno)")
		return client
	}

	private func connectLoopback(_ port: Int) throws -> NBDTestClient {
		let descriptor = socket(AF_INET, SOCK_STREAM, 0)
		var address = sockaddr_in()
		address.sin_family = sa_family_t(AF_INET)
		address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
		address.sin_port = UInt16(port).bigEndian
		address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
		let connected = withUnsafePointer(to: &address) { pointer in
			pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
		}
		let client = NBDTestClient(descriptor: descriptor)
		try #require(connected == 0, "connect failed with errno \(errno)")
		return client
	}

	@Test func aUnixSocketServerNamesItsSocketInTheURLAndRemovesItOnStop() throws {
		defer { finish() }
		let path = scratch.directory.appending(path: "nbd.sock").path

		let url = try server.start(.unixSocket(path: path))
		let client = try connectUnixSocket(path)
		try client.connect()
		let written = try client.write([42], at: 7)

		#expect(url.absoluteString == "nbd+unix:///library?socket=\(path)")
		#expect(url == NBDServer.url(for: .unixSocket(path: path)))
		#expect(written.error == 0)
		#expect(try scratch.disk.read(at: 7, count: 1) == [42])
		server.stop()
		#expect(client.isClosedByServer)
		#expect(!FileManager.default.fileExists(atPath: path))
	}

	@Test func aLoopbackServerNamesItsPortInTheURL() throws {
		defer { finish() }

		let url = try server.start(.loopback(port: 0))
		let port = try #require(url.port)
		let client = try connectLoopback(port)
		try client.connect()

		#expect(url.absoluteString == "nbd://127.0.0.1:\(port)/library")
		#expect(url == NBDServer.url(for: .loopback(port: UInt16(port))))
		#expect(try client.read(at: 3, count: 1).data == [3])
	}

	@Test func restoringPowerDisconnectsTheFirstBootAndTheNextBootReadsWhatWasAcknowledged() throws {
		defer { finish() }
		let path = scratch.directory.appending(path: "nbd.sock").path
		try server.start(.unixSocket(path: path))
		let firstBoot = try connectUnixSocket(path)
		try firstBoot.connect()
		_ = try firstBoot.write([1], at: 0)

		server.cutPower(tearingWith: nil)
		try server.restorePower()
		let secondBoot = try connectUnixSocket(path)
		try secondBoot.connect()

		#expect(firstBoot.isClosedByServer)
		#expect(try secondBoot.read(at: 0, count: 1).data == [1])
	}

	@Test func aStaleSocketIsReplacedButAnyOtherFileIsKept() throws {
		defer { finish() }
		let stale = scratch.directory.appending(path: "stale.sock").path
		let other = scratch.directory.appending(path: "other.sock").path
		let leftover = socket(AF_UNIX, SOCK_STREAM, 0)
		#expect(withUnixAddress(stale) { Darwin.bind(leftover, $0, $1) } == 0)
		close(leftover)
		try Data([1]).write(to: URL(fileURLWithPath: other))

		#expect(throws: NBDServer.Failure.notASocket(other)) { try NBDServer(disk: scratch.disk).start(.unixSocket(path: other)) }
		try server.start(.unixSocket(path: stale))
		let client = try connectUnixSocket(stale)

		#expect(try Data(contentsOf: URL(fileURLWithPath: other)) == Data([1]))
		try client.connect()
	}

	@Test func aSocketPathTooLongForTheKernelIsRefused() throws {
		defer { finish() }
		let path = "/tmp/" + String(repeating: "a", count: 104)

		#expect(throws: NBDServer.Failure.socketPathTooLong(path)) { try server.start(.unixSocket(path: path)) }
	}

	@Test func aServerStartsOnlyOnce() throws {
		defer { finish() }

		try server.start(.loopback(port: 0))

		#expect(throws: NBDServer.Failure.alreadyStarted) { try server.start(.loopback(port: 0)) }
	}
}
