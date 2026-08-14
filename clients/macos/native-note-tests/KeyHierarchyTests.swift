import Foundation
import Testing

@testable import NativeNote

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

struct Argon2VectorTests {
	@Test func matchesTheReferenceImplementation() throws {
		for vector in try Vectors.load("argon2.json") {
			let parameters = Argon2.Parameters(
				m: UInt32(try #require(vector.int("m"))),
				t: UInt32(try #require(vector.int("t"))),
				p: UInt32(try #require(vector.int("p")))
			)

			let out = try Argon2.hash(
				password: Data((try #require(vector.string("password"))).utf8),
				salt: try vector.require("salt"),
				parameters: parameters,
				length: try #require(vector.int("length"))
			)

			#expect(out == (try vector.require("output")), "case \(vector.name)")
		}
	}

	@Test func calibrationKeepsTheFloorWhenItAlreadyCostsTheTarget() throws {
		var readings = [0.0, 2.0].makeIterator()

		#expect(try Argon2.calibrateMemory(target: 1.0) { readings.next() ?? 0 } == Argon2.floor)
	}

	@Test func calibrationRaisesMemoryOnlyAndStaysAMultipleOfEightLanes() throws {
		var readings = [0.0, 0.25].makeIterator()

		let parameters = try Argon2.calibrateMemory(target: 1.0) { readings.next() ?? 0 }

		#expect(parameters.m == 4 * Argon2.floor.m)
		#expect(parameters.t == Argon2.floor.t)
		#expect(parameters.p == Argon2.floor.p)
		#expect(parameters.m.isMultiple(of: 8 * parameters.p))
	}

	@Test func calibrationNeverExceedsTheMemoryLimit() throws {
		var readings = [0.0, 0.001].makeIterator()

		let parameters = try Argon2.calibrateMemory(target: 1.0, limit: 512 * 1024) { readings.next() ?? 0 }

		#expect(parameters.m == 512 * 1024)
	}

	@Test func rejectsParametersBelowTheAlgorithmMinimum() {
		#expect(throws: Argon2.Failure.self) {
			try Argon2.hash(
				password: Data("x".utf8),
				salt: Data(repeating: 0, count: 16),
				parameters: Argon2.Parameters(m: 1, t: 0, p: 1)
			)
		}
	}
}
