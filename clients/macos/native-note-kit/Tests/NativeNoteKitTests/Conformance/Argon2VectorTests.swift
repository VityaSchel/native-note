import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct Argon2VectorTests {
	@Test func matchesTheReferenceImplementation() throws {
		for vector in try Vectors.load(.argon2) {
			let parameters = Argon2.Parameters(
				m: UInt32(try #require(vector.int("m"))),
				t: UInt32(try #require(vector.int("t"))),
				p: UInt32(try #require(vector.int("p")))
			)

			let password = try #require(vector.string("password"))
			#expect(Data(password.utf8) == (try vector.require("passwordUtf8")), "case \(vector.name)")

			let out = try Argon2.hash(
				password: password,
				salt: try vector.require("salt"),
				parameters: parameters,
				length: try #require(vector.int("length"))
			)

			#expect(out == SymmetricKey(data: try vector.require("output")), "case \(vector.name)")
		}
	}
}
