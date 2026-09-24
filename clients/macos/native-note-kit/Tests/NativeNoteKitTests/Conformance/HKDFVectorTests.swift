import Foundation
import Testing

@testable import NativeNoteKit

struct HKDFVectorTests {
	@Test func everyLabelMatches() throws {
		let cases = try Vectors.load("hkdf.json")
		#expect(!cases.isEmpty)

		for vector in cases {
			let salt = vector.bytes("salt") ?? Data()
			let length = try #require(vector.int("length"))
			let info = try #require(vector.string("info"))

			let ikm = if vector.bytes("ikm") != nil {
				try vector.require("ikm")
			} else {
				try vector.require("argonOut") + vector.require("machineId")
			}

			let okm = KeyDerivation.derive(ikm: ikm, salt: salt, info: info, length: length)

			#expect(okm == (try vector.require("okm")), "label \(vector.name)")
		}
	}

	@Test func labelConstantsMatchTheSpec() throws {
		let labels = try Vectors.load("hkdf.json").reduce(into: [String: String]()) { labels, vector in
			labels[vector.name] = vector.string("info")
		}

		#expect(labels["envelopeKey"] == KeyDerivation.envelope)
		#expect(labels["blindingKey"] == KeyDerivation.idBlind)
		#expect(labels["noteKey"] == KeyDerivation.note)
		#expect(labels["localDbKey"] == KeyDerivation.localDb)
		#expect(labels["machineId"] == KeyDerivation.machineId)
	}

	@Test func localDbKeyConcatenatesArgonOutputAndMachineId() throws {
		let vector = try #require(try Vectors.load("hkdf.json").first { $0.name == "localDbKey" })

		let key = KeyDerivation.localDbKey(
			argonOut: try vector.require("argonOut"),
			machineId: try vector.require("machineId"),
			localSalt: try vector.require("salt")
		)

		#expect(key == (try vector.require("okm")))
	}
}
