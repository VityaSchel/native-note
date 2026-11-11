import Foundation
import Network
import Testing

@testable import NativeNoteKit

/// A listener that records the head of the first request it takes and answers every request with `reply`.
final class HeadCapture: @unchecked Sendable {
	private let listener: NWListener
	private let reply: String
	private let lock = NSLock()
	private var received = Data()
	private var waiting: CheckedContinuation<Data, Never>?
	private(set) var connections = 0

	init(reply: String = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") throws {
		listener = try NWListener(using: .tcp, on: .any)
		self.reply = reply
	}

	func start() async throws -> URL {
		let port: UInt16 = try await withCheckedThrowingContinuation { started in
			listener.stateUpdateHandler = { [listener] state in
				switch state {
				case .ready: started.resume(returning: listener.port?.rawValue ?? 0)
				case let .failed(error): started.resume(throwing: error)
				default: break
				}
			}
			listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
			listener.start(queue: .global())
		}
		listener.stateUpdateHandler = nil
		return try #require(URL(string: "http://127.0.0.1:\(port)/"))
	}

	func head() async -> String {
		let data = await withCheckedContinuation { continuation in
			lock.withLock {
				if received.range(of: Data("\r\n\r\n".utf8)) != nil { continuation.resume(returning: received) } else { waiting = continuation }
			}
		}
		return String(decoding: data.prefix(upTo: data.range(of: Data("\r\n\r\n".utf8))?.lowerBound ?? data.endIndex), as: UTF8.self)
	}

	func stop() {
		listener.cancel()
	}

	private func serve(_ connection: NWConnection) {
		lock.withLock { connections += 1 }
		connection.start(queue: .global())
		read(connection)
	}

	private func read(_ connection: NWConnection) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
			guard let self else { return }
			let complete = lock.withLock {
				received.append(data ?? Data())
				guard received.range(of: Data("\r\n\r\n".utf8)) != nil else { return false }
				waiting?.resume(returning: received)
				waiting = nil
				return true
			}
			if complete || done || error != nil {
				connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
			} else {
				read(connection)
			}
		}
	}
}

struct TransportHeaderTests {
	@Test func aRedirectIsReportedNotFollowed() async throws {
		let capture = try HeadCapture(reply: "HTTP/1.1 301 Moved Permanently\r\nLocation: /elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
		defer { capture.stop() }
		let url = try await capture.start()

		await #expect(throws: SyncError.refused(status: 301)) { try await HTTPTransport(url: url).post(Data(count: 256)) }

		#expect(capture.connections == 1)
	}

	@Test func aRequestCarriesOnlyFixedHeadersTheSameOnEveryMac() async throws {
		let capture = try HeadCapture()
		defer { capture.stop() }
		let url = try await capture.start()

		await #expect(throws: SyncError.refused(status: 404)) { try await HTTPTransport(url: url).post(Data(count: 256)) }

		let lines = await capture.head().components(separatedBy: "\r\n")
		#expect(lines.first == "POST / HTTP/1.1")
		let fields = Dictionary(lines.dropFirst().map { line in
			let (name, value) = (line.prefix { $0 != ":" }, line.drop { $0 != ":" }.dropFirst())
			return (name.lowercased(), value.trimmingCharacters(in: .whitespaces))
		}, uniquingKeysWith: { first, _ in first })
		let fixed = Dictionary(uniqueKeysWithValues: HTTPTransport.headers.map { ($0.key.lowercased(), $0.value) })
		#expect(Set(fields.keys).subtracting(fixed.keys).subtracting(["host", "content-length", "connection"]).isEmpty, "\(fields)")
		for (name, value) in fixed {
			#expect(fields[name] == value, "\(name)")
		}
		#expect(fields["content-length"] == "256")
		#expect(fields["connection"].map { $0 == "keep-alive" || $0 == "close" } ?? true)
		let head = lines.joined(separator: "\n")
		for leak in ["Darwin", "CFNetwork", "Native%20Note", Locale.preferredLanguages.first ?? "en"] where leak != "*" {
			#expect(!head.contains(leak), "\(leak)")
		}
	}
}
