import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct ExchangeVectorTests {
	@Test func eachSyncStepSealsItsWritesExactlyAndReadsTheOutcomeItsResponseCarries() throws {
		var copyId: UUID?
		for step in try Vectors.load(.sync) {
			let cipher = NoteCipher(contentKey: try key(step, "contentKey"))
			guard case let .sync(since, sent) = try RequestDecoding.decode(try step.require("request")) else {
				Issue.record("\(step.name) is not a sync")
				continue
			}
			let writes = try #require(step.objects("writes"))
			#expect(writes.count == sent.count, "\(step.name)")
			var sealed: [Write] = []
			for (write, request) in zip(writes, sent) {
				let content = try content(from: try #require(write["content"] as? [String: Any]))
				let writeId = try #require((write["writeId"] as? String).flatMap(Hex.decode))
				let nonce = try AES.GCM.Nonce(data: try #require((write["nonce"] as? String).flatMap(Hex.decode)))
				sealed.append(try cipher.seal(content, v: request.v, writeId: writeId, nonce: nonce))
				if content.id == copyId { copyId = nil }
			}
			#expect(Request.sync(since: since, writes: sealed).encoded() == (try step.require("request")), "\(step.name)")
			if let copy = step.string("copyUuid") { copyId = UUID(uuidString: copy) }

			guard case let .sync(results, changes, _, more) = try Response.decode(try step.require("response")) else {
				Issue.record("\(step.name) got no sync response")
				continue
			}
			let outcome = try #require(step.object("outcome"))
			let expected = try #require(outcome["results"] as? [[String: Any]]).map { result in
				(result["status"] as? String, (result["v"] as? Int).map(UInt32.init), (result["seq"] as? Int).map(UInt64.init))
			}
			#expect(results.map { (Self.name(of: $0.status), Optional($0.v), Optional($0.seq)) }.elementsEqual(expected, by: ==), "\(step.name)")
			#expect(changes.count == outcome["changes"] as? Int, "\(step.name)")
			#expect(!more)
			for change in changes {
				let opened = try #require(cipher.open(change), "\(step.name)")
				#expect(cipher.blindedId(for: opened.id) == change.blindedId, "\(step.name)")
			}
		}
		#expect(copyId == nil, "the conflict copy was pushed")
	}

	@Test func eachRecoveryExchangeReEncodesAndItsBlobOpensOnlyUnderTheKeyThatSealedIt() throws {
		for exchange in try Vectors.load(.recovery) where exchange.bytes("request") != nil {
			let request = try exchange.require("request")
			let response = try Response.decode(try exchange.require("response"))
			switch try RequestDecoding.decode(request) {
			case .get:
				#expect(Request.get.encoded() == request)
				guard case let .get(v, blob) = response else {
					Issue.record("\(exchange.name) got no get response")
					continue
				}
				#expect((v == 0) == blob.isEmpty, "\(exchange.name)")
				if let opens = exchange.bool("opens") {
					#expect((RecoveryBlob.open(blob, under: try key(exchange, "recoveryKey")) != nil) == opens, "\(exchange.name)")
				}
			case let .put(v, _):
				let blob = try RecoveryBlob.seal(try key(exchange, "contentKey"), under: try key(exchange, "recoveryKey"), nonce: try nonce(exchange))
				#expect(Request.put(v: v, blob: blob).encoded() == request, "\(exchange.name)")
				guard case .put = response else {
					Issue.record("\(exchange.name) got no put response")
					continue
				}
			case .sync:
				Issue.record("\(exchange.name) is a sync")
			}
		}
	}

	private static func name(of status: Status) -> String {
		switch status {
		case .accepted: "accepted"
		case .conflict: "conflict"
		case .tooLarge: "too_large"
		}
	}
}
