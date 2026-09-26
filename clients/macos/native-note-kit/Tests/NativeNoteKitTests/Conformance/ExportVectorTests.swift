import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

struct ExportVectorTests {
	private struct Reference {
		let vector: Vectors.Case
		let passphrase: String
		let parameters: Argon2.Parameters
		let salt: Data

		init() throws {
			vector = try #require(try Vectors.load(.export).first { $0.name == "export" })
			passphrase = try #require(vector.string("passphrase"))
			parameters = Argon2.Parameters(
				m: UInt32(try #require(vector.int("m"))),
				t: UInt32(try #require(vector.int("t"))),
				p: UInt32(try #require(vector.int("p")))
			)
			salt = try vector.require("salt")
		}
	}

	@Test func derivesTheHeaderAndKeyFromTheFixedInputs() throws {
		let reference = try Reference()

		#expect(ExportEnvelope.header(parameters: reference.parameters, salt: reference.salt) == (try reference.vector.require("header")))

		let key = try ExportEnvelope.key(passphrase: reference.passphrase, salt: reference.salt, parameters: reference.parameters)
		#expect(key.withUnsafeBytes { Data($0) } == (try reference.vector.require("exportKey")))
	}

	@Test func sealsTheFixedInputsToExactlyTheReferenceFile() throws {
		let reference = try Reference()

		let file = try ExportEnvelope.seal(
			try reference.vector.require("zip"),
			passphrase: reference.passphrase,
			parameters: reference.parameters,
			salt: reference.salt,
			nonce: try AES.GCM.Nonce(data: try reference.vector.require("nonce"))
		)

		#expect(file == (try reference.vector.require("file")))
	}

	@Test func everyCaseOpensOrIsRejectedAsDeclared() throws {
		let cases = try Vectors.load(.export)
		#expect(cases.count == 7)

		for vector in cases {
			let file = try vector.require("file")
			let passphrase = try #require(vector.string("passphrase"))
			let opens = try #require(vector.bool("opens") as Bool?, "case \(vector.name)")
			#expect(ExportEnvelope.isEncrypted(file) == (vector.name != "rejectBadMagic"), "case \(vector.name)")

			if opens {
				#expect(try ExportEnvelope.open(file, passphrase: passphrase) == (try vector.require("zip")), "case \(vector.name)")
			} else {
				let expected: ExportEnvelope.Failure = switch vector.name {
				case "rejectBadMagic": .notAnExport
				case "rejectParametersOutOfBounds": .parametersOutOfBounds
				default: .wrongPassphraseOrDamaged
				}
				#expect(throws: expected, "case \(vector.name)") {
					try ExportEnvelope.open(file, passphrase: passphrase)
				}
			}
		}
	}
}
