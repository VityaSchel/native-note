import Foundation
import Testing

@testable import NativeNoteKit

struct CodecVectorTests {
	@Test func contentEncodesAndDecodesExactlyAndRejectsWhatTheSpecRejects() throws {
		for vector in try Vectors.load(.content) {
			let encoded = try vector.require("encoded")
			if vector.bool("roundTrips") == true {
				let expected = try content(from: try #require(vector.object("content")))
				#expect(expected.encoded() == encoded, "\(vector.name)")
				#expect(try Content.decode(encoded) == expected, "\(vector.name)")
			} else {
				#expect(vector.bool("decodes") == false)
				#expect(throws: try wireError(named: vector.string("error")), "\(vector.name)") {
					try Content.decode(encoded)
				}
			}
		}
	}

	/// Request decoding is the server's, replayed by the core; the client only encodes requests.
	private static let serverOnly: Set = [
		"rejectUnknownAction", "rejectImpossibleCount", "rejectImpossibleLength", "rejectTrailingBytes", "rejectErrorAsRequest",
	]

	@Test func responsesDecodeExactlyAndRequestsReEncodeByteForByte() throws {
		var replayed: Set<String> = []
		for vector in try Vectors.load(.frames) {
			let encoded = try vector.require("encoded")
			switch (vector.string("direction"), vector.bool("roundTrips") == true) {
			case ("request", true):
				#expect(try RequestDecoding.decode(encoded).encoded() == encoded, "\(vector.name)")
			case ("response", true):
				#expect(try responseBytes(Response.decode(encoded)) == encoded, "\(vector.name)")
			case ("response", false):
				#expect(throws: try wireError(named: vector.string("error")), "\(vector.name)") {
					try Response.decode(encoded)
				}
			default:
				#expect(Self.serverOnly.contains(vector.name), "\(vector.name) is neither replayed nor listed as server-only")
				continue
			}
			replayed.insert(vector.name)
		}
		#expect(replayed.count >= 19)
	}

	@Test func paddingFillsTheSmallestBucketAndUnpadsOnlyItsOwnOutput() throws {
		for vector in try Vectors.load(.padding) {
			if let length = vector.int("innerLength") {
				let inner = Data((0 ..< length).map { UInt8(truncatingIfNeeded: $0) })
				guard vector.bool("pads") != false else {
					#expect(Padding.pad(inner) == nil, "\(vector.name)")
					continue
				}
				let padded = try #require(Padding.pad(inner), "\(vector.name)")
				#expect(padded.count == vector.int("paddedLength"), "\(vector.name)")
				#expect(padded.prefix(4) == (try vector.require("lengthPrefix")), "\(vector.name)")
				#expect(Padding.unpad(padded) == inner, "\(vector.name)")
			} else {
				#expect(vector.bool("unpads") == false)
				#expect(Padding.unpad(try vector.require("padded")) == nil, "\(vector.name)")
			}
		}
	}
}
