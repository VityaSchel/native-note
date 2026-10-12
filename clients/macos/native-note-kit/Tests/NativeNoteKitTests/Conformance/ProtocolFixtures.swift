import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

func key(_ vector: Vectors.Case, _ field: String) throws -> SymmetricKey {
	SymmetricKey(data: try vector.require(field))
}

func nonce(_ vector: Vectors.Case, _ field: String = "nonce") throws -> AES.GCM.Nonce {
	try AES.GCM.Nonce(data: try vector.require(field))
}

func content(from object: [String: Any]) throws -> Content {
	let id = try #require((object["uuid"] as? String).flatMap(Hex.decode).flatMap { UUID(bytes: $0) })
	let int = { (key: String) throws -> Int64 in Int64(try #require(object[key] as? Int, "content has no \(key)")) }
	switch object["kind"] as? String {
	case "note":
		return .note(id: id, createdAt: try int("createdAt"), updatedAt: try int("updatedAt"), body: try #require(object["body"] as? String))
	case "tombstone":
		return .tombstone(id: id, deletedAt: try int("deletedAt"))
	default:
		throw WireError.unknownDiscriminant
	}
}

func wireError(named name: String?) throws -> WireError {
	switch name {
	case "Truncated": .truncated
	case "TrailingBytes": .trailingBytes
	case "UnknownDiscriminant": .unknownDiscriminant
	case "NotCanonical": .notCanonical
	default: throw WireError.unknownDiscriminant
	}
}

/// The server's half of the frame codec, so the tests can read the requests a vector carries.
enum RequestDecoding {
	static func decode(_ bytes: Data) throws -> Request {
		var reader = WireReader(bytes)
		let request: Request
		switch try reader.u8() {
		case 0x01:
			let since = try reader.u64()
			let writes = try reader.items { (reader: inout WireReader) throws(WireError) in
				Write(blindedId: try reader.take(16), v: try reader.u32(), writeId: try reader.take(16), payload: try reader.bytes())
			}
			request = .sync(since: since, writes: writes)
		case 0x02:
			request = .get
		case 0x03:
			request = .put(v: try reader.u32(), blob: try reader.bytes())
		default:
			throw WireError.unknownDiscriminant
		}
		try reader.finish()
		return request
	}
}

/// The server's response encoder, for vectors that round-trip and for scripted servers.
func responseBytes(_ response: Response) -> Data {
	var writer = WireWriter()
	switch response {
	case let .sync(results, changes, nextSeq, more):
		writer.u8(0x01)
		writer.u32(UInt32(results.count))
		for result in results {
			writer.u8(result.status.rawValue)
			writer.u32(result.v)
			writer.u64(result.seq)
		}
		writer.fixed(Request.sync(since: 0, writes: changes).encoded().dropFirst(Request.syncHeaderLength - 4))
		writer.u64(nextSeq)
		writer.u8(more ? 1 : 0)
	case let .get(v, blob):
		writer.u8(0x02)
		writer.u32(v)
		writer.bytes(blob)
	case let .put(status, v):
		writer.u8(0x03)
		writer.u8(status.rawValue)
		writer.u32(v)
	case .error:
		writer.u8(0xff)
	}
	return writer.data
}
