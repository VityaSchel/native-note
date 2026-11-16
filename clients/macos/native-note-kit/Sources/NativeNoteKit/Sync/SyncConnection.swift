import CryptoKit
import Foundation

nonisolated protocol SyncTransport: Sendable {
	func post(_ body: Data) async throws -> Data
}

nonisolated enum SyncError: Error, Equatable {
	case refused(status: Int)
	case unopenable
	case requestMalformed
	case unsupported
	case serverFault
	case protocolViolation

	init(_ reason: ErrorReason) {
		switch reason {
		case .malformed: self = .requestMalformed
		case .unsupported: self = .unsupported
		case .fault: self = .serverFault
		}
	}

	var refusedUnread: Bool {
		self == .requestMalformed || self == .unsupported
	}
}

nonisolated struct HTTPTransport: SyncTransport {
	static let fingerprintFreeHeaders = [
		"User-Agent": "native-note",
		"Accept": "*/*",
		"Accept-Language": "*",
		"Accept-Encoding": "identity",
		"Content-Type": "application/octet-stream",
	]

	private static let sharedSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 30
		configuration.timeoutIntervalForResource = 120
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		return URLSession(configuration: configuration)
	}()

	private let url: URL
	let session = HTTPTransport.sharedSession

	init(url: URL) {
		self.url = url
	}

	func post(_ body: Data) async throws -> Data {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = body
		for (name, value) in Self.fingerprintFreeHeaders {
			request.setValue(value, forHTTPHeaderField: name)
		}
		let (reply, response) = try await session.data(for: request, delegate: NoRedirects.shared)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard status == 200 else { throw SyncError.refused(status: status) }
		return reply
	}
}

private nonisolated final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
	static let shared = NoRedirects()

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping @Sendable (URLRequest?) -> Void
	) {
		completionHandler(nil)
	}
}

nonisolated struct SyncConnection: Sendable {
	private let envelope: EnvelopeKey
	private let transport: any SyncTransport

	init(apiKey: SymmetricKey, transport: any SyncTransport) {
		envelope = EnvelopeKey(apiKey: apiKey)
		self.transport = transport
	}

	func send(_ request: Request) async throws -> Response {
		let nonce = AES.GCM.Nonce()
		let reply = try await transport.post(try envelope.seal(request.encoded(), nonce: nonce))
		let inner: Data
		do {
			inner = try envelope.open(reply, requestNonce: Data(nonce))
		} catch {
			throw SyncError.unopenable
		}
		guard let response = try? Response.decode(inner) else { throw SyncError.protocolViolation }
		if case let .error(reason) = response { throw SyncError(reason) }
		return response
	}
}
