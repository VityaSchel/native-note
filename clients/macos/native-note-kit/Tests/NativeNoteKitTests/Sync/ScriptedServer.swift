import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

final class ScriptedServer: SyncTransport, @unchecked Sendable {
	let apiKey = SymmetricKey(size: .bits256)
	private let lock = NSLock()
	private var replies: [(Request) throws -> Response] = []
	private(set) var requests: [Request] = []

	func answer(_ reply: @escaping (Request) -> Response) {
		lock.withLock { replies.append(reply) }
	}

	func refuse(status: Int = 502) {
		lock.withLock { replies.append { _ in throw SyncError.refused(status: status) } }
	}

	func post(_ body: Data) async throws -> Data {
		let key = KeyDerivation.derive(ikm: apiKey, info: KeyDerivation.envelope)
		let padded = try AES.GCM.open(AES.GCM.SealedBox(combined: body), using: key)
		let request = try RequestDecoding.decode(try #require(Padding.unpad(padded)))
		let reply = try lock.withLock {
			requests.append(request)
			return try #require(replies.isEmpty ? nil : replies.removeFirst(), "no reply scripted for \(request)")
		}
		let response = try reply(request)
		let inner = try #require(Padding.pad(responseBytes(response)))
		return try #require(try AES.GCM.seal(inner, using: key, authenticating: body.prefix(EnvelopeKey.nonceLength)).combined)
	}

	@MainActor
	func device(_ store: NoteStore, contentKey: SymmetricKey = sharedContentKey) -> SyncEngine {
		SyncEngine(store: store, settings: SyncSettings(server: URL(string: "http://scripted.test/")!, apiKey: apiKey, contentKey: contentKey), transport: self)
	}
}

func misfiled(_ content: Content, under blindedId: Data, v: UInt32, contentKey: SymmetricKey = sharedContentKey) throws -> Write {
	let writeId = NoteCipher.randomWriteId()
	var binding = WireWriter()
	binding.fixed(blindedId)
	binding.u32(v)
	binding.fixed(writeId)
	let key = KeyDerivation.derive(ikm: contentKey, salt: writeId, info: KeyDerivation.note)
	let sealed = try AES.GCM.seal(content.encoded(), using: key, authenticating: binding.data)
	return Write(blindedId: blindedId, v: v, writeId: writeId, payload: try #require(sealed.combined))
}
