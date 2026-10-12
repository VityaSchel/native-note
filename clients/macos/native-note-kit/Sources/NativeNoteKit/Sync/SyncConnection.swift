import CryptoKit
import Foundation

nonisolated protocol SyncTransport: Sendable {
	func post(_ body: Data) async throws -> Data
}

nonisolated enum SyncError: Error, Equatable {
	/// The server answered with a status, never a sealed reply: the API key is wrong, or the server is not Native Note.
	case refused(status: Int)
	case unopenable
	case serverFault
	/// A response the protocol does not allow, so nothing of it was applied.
	case protocolViolation
}

nonisolated struct HTTPTransport: SyncTransport {
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
		let (reply, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		guard status == 200 else { throw SyncError.refused(status: status) }
		return reply
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
