import CryptoKit
import Foundation

nonisolated protocol SyncTransport: Sendable {
	func post(_ body: Data) async throws -> Data
}

nonisolated enum SyncError: Error, Equatable {
	/// A bare status instead of a sealed reply: 400 when the server cannot open or parse the request, which a proxy can cause too, anything else from a proxy, a redirect or a fault.
	case refused(status: Int)
	case unopenable
	case serverFault
	/// A response the protocol does not allow, so nothing of it was applied.
	case protocolViolation
}

nonisolated struct HTTPTransport: SyncTransport {
	/// The same on every Mac, so nothing outside the envelope tells devices, builds or languages apart.
	static let headers = [
		"User-Agent": "native-note",
		"Accept": "*/*",
		"Accept-Language": "*",
		"Accept-Encoding": "identity",
		"Content-Type": "application/octet-stream",
	]

	private let url: URL
	private let session: URLSession

	init(url: URL) {
		self.url = url
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 30
		configuration.timeoutIntervalForResource = 120
		configuration.httpShouldSetCookies = false
		configuration.urlCache = nil
		session = URLSession(configuration: configuration)
	}

	func post(_ body: Data) async throws -> Data {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.httpBody = body
		for (name, value) in Self.headers {
			request.setValue(value, forHTTPHeaderField: name)
		}
		let (reply, response) = try await session.data(for: request, delegate: NoRedirects.shared)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard status == 200 else { throw SyncError.refused(status: status) }
		return reply
	}
}

/// A redirect would turn the POST into a GET the server can only refuse, so its status is reported instead.
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
		if response == .error { throw SyncError.serverFault }
		return response
	}
}
