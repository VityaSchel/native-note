import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct HKDFVectorTests {
	@Test func everyLabelMatches() throws {
		let cases = try Vectors.load(.hkdf)
		#expect(!cases.isEmpty)

		for vector in cases {
			let salt = vector.bytes("salt") ?? Data()
			let length = try #require(vector.int("length"))
			let info = try #require(vector.string("info"))

			let ikm = try vector.bytes("ikm") ?? (vector.require("argonOut") + vector.require("machineId"))

			let okm = KeyDerivation.derive(ikm: SymmetricKey(data: ikm), salt: salt, info: info, length: length)

			#expect(okm == SymmetricKey(data: try vector.require("okm")), "label \(vector.name)")
		}
	}

	@Test func labelConstantsMatchTheSpec() throws {
		let labels = try Vectors.load(.hkdf).reduce(into: [String: String]()) { labels, vector in
			labels[vector.name] = vector.string("info")
		}

		#expect(labels["envelopeKey"] == KeyDerivation.envelope)
		#expect(labels["blindingKey"] == KeyDerivation.idBlind)
		#expect(labels["noteKey"] == KeyDerivation.note)
		#expect(labels["localDbKey"] == KeyDerivation.localDb)
		#expect(labels["machineId"] == KeyDerivation.machineId)
	}

	@Test(arguments: ["localDbKey", "localDbKeyWithoutMachineId"])
	func localDbKeyMatchesItsVector(name: String) throws {
		let vector = try #require(try Vectors.load(.hkdf).first { $0.name == name })

		let key = KeyDerivation.localDbKey(
			argonOut: SymmetricKey(data: try vector.bytes("argonOut") ?? vector.require("ikm")),
			machineId: vector.bytes("machineId").map { SymmetricKey(data: $0) },
			localSalt: try vector.require("salt")
		)

		#expect(key == SymmetricKey(data: try vector.require("okm")))
	}
}
