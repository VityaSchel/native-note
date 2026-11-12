import Darwin
import Foundation
import Synchronization

public final class NBDServer: Sendable {
	public enum Failure: Error, Equatable {
		case alreadyStarted
		case socketPathTooLong(String)
		case notASocket(String)
		case system(call: String, errno: Int32)
		case sessionsOutliveTheCut(Int)
	}

	private struct Registry {
		var listener: Int32 = -1
		var wake: (read: Int32, write: Int32) = (-1, -1)
		var socketPath: String?
		var sessions: Set<Int32> = []
		var isStopping = false
	}

	public let disk: OrderedDisk
	public let export: NBDExport
	private let log: @Sendable (String) -> Void
	private let ledger = NBDLedger()
	private let registry = Mutex(Registry())
	private let running = DispatchGroup()

	public init(disk: OrderedDisk, export: NBDExport = NBDExport(), log: @escaping @Sendable (String) -> Void = { _ in }) {
		self.disk = disk
		self.export = export
		self.log = log
	}

	public var activity: DiskActivity {
		ledger.activity
	}

	public var cut: CutReport {
		CutReport(torn: disk.tornWrite, dropped: ledger.dropped)
	}

	@discardableResult
	public func start(socketPath: String) throws -> URL {
		guard registry.withLock({ $0.listener < 0 && !$0.isStopping }) else { throw Failure.alreadyStarted }
		let listener = try bindUnixSocket(at: socketPath)
		let url = Self.url(socketPath: socketPath, export: export)
		var wake: [Int32] = [-1, -1]
		guard pipe(&wake) == 0 else {
			let failure = Failure.system(call: "pipe", errno: errno)
			close(listener)
			throw failure
		}
		let (wakeRead, wakeWrite) = (wake[0], wake[1])
		for descriptor in [wakeRead, wakeWrite] {
			_ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
		}
		registry.withLock { registry in
			registry.listener = listener
			registry.wake = (wakeRead, wakeWrite)
			registry.socketPath = socketPath
		}
		running.enter()
		Thread { [self] in
			acceptConnections(on: listener, until: wakeRead)
			running.leave()
		}.start()
		log("nbd: serving \(url.absoluteString)")
		return url
	}

	public func cutPower(tearingWith seed: UInt64?) {
		disk.cutPower(tearingWith: seed)
		log("nbd: power cut, \(seed.map { "tearing the first change after it with seed \($0)" } ?? "tearing nothing")")
	}

	public func restorePower(within timeout: Duration = .seconds(10)) throws {
		let deadline = ContinuousClock.now + timeout
		while sessionCount > 0, ContinuousClock.now < deadline {
			disconnect()
			usleep(1_000)
		}
		guard sessionCount == 0 else { throw Failure.sessionsOutliveTheCut(sessionCount) }
		disk.restorePower()
	}

	public func stop() {
		let wake = registry.withLock { registry in
			registry.isStopping = true
			return registry.wake.write
		}
		if wake >= 0 {
			var byte: UInt8 = 1
			_ = write(wake, &byte, 1)
		}
		disconnect()
		if running.wait(timeout: .now() + .seconds(10)) == .timedOut {
			log("nbd: sessions still running after stop")
		}
		registry.withLock { registry in
			for descriptor in [registry.listener, registry.wake.read, registry.wake.write] where descriptor >= 0 {
				close(descriptor)
			}
			if let path = registry.socketPath {
				unlink(path)
			}
			registry = Registry()
			registry.isStopping = true
		}
	}

	func adopt(_ connection: Int32) {
		_ = fcntl(connection, F_SETFD, FD_CLOEXEC)
		var enabled: Int32 = 1
		setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
		let admitted = registry.withLock { registry in
			guard !registry.isStopping else { return false }
			registry.sessions.insert(connection)
			running.enter()
			return true
		}
		guard admitted else {
			close(connection)
			return
		}
		Thread { [self] in
			NBDSession(channel: SocketChannel(descriptor: connection), disk: disk, export: export, ledger: ledger, log: log).run()
			registry.withLock { registry in
				registry.sessions.remove(connection)
				close(connection)
			}
			running.leave()
		}.start()
	}

	var sessionCount: Int {
		registry.withLock { $0.sessions.count }
	}

	public func disconnect() {
		registry.withLock { registry in
			for session in registry.sessions {
				shutdown(session, SHUT_RDWR)
			}
		}
	}

	private func acceptConnections(on listener: Int32, until wake: Int32) {
		var watched = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0), pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
		while true {
			watched[0].revents = 0
			watched[1].revents = 0
			guard poll(&watched, 2, -1) >= 0 || errno == EINTR else {
				log("nbd: poll failed with errno \(errno)")
				return
			}
			if watched[1].revents != 0 { return }
			guard watched[0].revents != 0 else { continue }
			let connection = accept(listener, nil, nil)
			if connection >= 0 {
				adopt(connection)
			} else if errno != EINTR, errno != ECONNABORTED {
				log("nbd: accept failed with errno \(errno)")
				return
			}
		}
	}

	private static func url(socketPath: String, export: NBDExport) -> URL {
		var components = URLComponents()
		components.scheme = "nbd+unix"
		components.host = ""
		components.path = "/" + export.name
		components.queryItems = [URLQueryItem(name: "socket", value: socketPath)]
		return components.url!
	}

	private func bindUnixSocket(at path: String) throws -> Int32 {
		var address = sockaddr_un()
		let pathBytes = Array(path.utf8)
		guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.socketPathTooLong(path) }
		var existing = stat()
		if lstat(path, &existing) == 0 {
			guard existing.st_mode & S_IFMT == S_IFSOCK else { throw Failure.notASocket(path) }
			unlink(path)
		}
		address.sun_family = sa_family_t(AF_UNIX)
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
		let listener = try unixSocketDescriptor()
		do {
			try withUnsafePointer(to: &address) { pointer in
				try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					try check("bind", Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)))
				}
			}
			try check("listen", Darwin.listen(listener, 8))
		} catch {
			close(listener)
			throw error
		}
		return listener
	}

	private func unixSocketDescriptor() throws -> Int32 {
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw Failure.system(call: "socket", errno: errno) }
		_ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
		return descriptor
	}

	private func check(_ call: String, _ result: Int32) throws {
		guard result == 0 else { throw Failure.system(call: call, errno: errno) }
	}
}
