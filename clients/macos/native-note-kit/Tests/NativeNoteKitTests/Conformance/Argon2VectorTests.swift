import Foundation
import Testing

@testable import NativeNoteKit

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
}
