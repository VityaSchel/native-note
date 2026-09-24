import Foundation
import Testing

@testable import NativeNoteKit

struct ExportEnvelopeTests {
	private static let fast = Argon2.Parameters(m: 1024, t: 1, p: 1)
	private static let zip = Data("PK\u{3}\u{4}two notes".utf8)

	private static func file(claiming parameters: Argon2.Parameters) -> Data {
		ExportEnvelope.header(parameters: parameters, salt: Data(count: 16)) + Data(count: 12 + 16)
	}

	@Test func roundTripsUnderAFreshSaltAndNonceEachTime() throws {
		let first = try ExportEnvelope.seal(Self.zip, passphrase: "hunter2", parameters: Self.fast)
		let second = try ExportEnvelope.seal(Self.zip, passphrase: "hunter2", parameters: Self.fast)

		#expect(first.dropFirst(21).prefix(16) != second.dropFirst(21).prefix(16))
		#expect(first.dropFirst(37).prefix(12) != second.dropFirst(37).prefix(12))
		#expect(try ExportEnvelope.open(first, passphrase: "hunter2") == Self.zip)
		#expect(try ExportEnvelope.open(second, passphrase: "hunter2") == Self.zip)
	}

	@Test func sealsUnderTheArgon2FloorByDefault() throws {
		let file = try ExportEnvelope.seal(Data(), passphrase: "floor")

		#expect(file.prefix(9) == Data("NNEXPORT1".utf8))
		#expect(file.dropFirst(9).prefix(12) == Data([0, 4, 0, 0, 0, 0, 0, 3, 0, 0, 0, 4]))
	}

	@Test func recognizesOnlyTheExportMagic() throws {
		#expect(ExportEnvelope.isEncrypted(try ExportEnvelope.seal(Self.zip, passphrase: "x", parameters: Self.fast)))
		#expect(!ExportEnvelope.isEncrypted(Self.zip))
		#expect(!ExportEnvelope.isEncrypted(Data("NNEXPORT2".utf8) + Data(count: 64)))
		#expect(!ExportEnvelope.isEncrypted(Data("NNEXPORT".utf8)))
		#expect(!ExportEnvelope.isEncrypted(Data()))
	}

	@Test func aWrongPassphraseAndADamagedFileFailTheSameWay() throws {
		let file = try ExportEnvelope.seal(Self.zip, passphrase: "right", parameters: Self.fast)
		var damaged = file
		damaged[damaged.endIndex - 1] ^= 0x01

		#expect(throws: ExportEnvelope.Failure.wrongPassphraseOrDamaged) {
			try ExportEnvelope.open(file, passphrase: "wrong")
		}
		#expect(throws: ExportEnvelope.Failure.wrongPassphraseOrDamaged) {
			try ExportEnvelope.open(damaged, passphrase: "right")
		}
	}

	@Test func rejectsFilesTooShortToHoldAHeaderNonceAndTag() throws {
		let file = try ExportEnvelope.seal(Data(), passphrase: "x", parameters: Self.fast)
		#expect(file.count == 9 + 12 + 16 + 12 + 16)

		for length in 0 ..< file.count {
			#expect(throws: ExportEnvelope.Failure.notAnExport, "length \(length)") {
				try ExportEnvelope.open(file.prefix(length), passphrase: "x")
			}
		}
		#expect(try ExportEnvelope.open(file, passphrase: "x") == Data())
	}

	@Test func opensAnExportHeldInASliceOfALargerBuffer() throws {
		let buffer = Data("prefix".utf8) + (try ExportEnvelope.seal(Self.zip, passphrase: "slice", parameters: Self.fast))

		#expect(try ExportEnvelope.open(buffer.dropFirst(6), passphrase: "slice") == Self.zip)
	}

	@Test func refusesAHeaderAskingForSixtyFourGibibytesWithoutHashing() {
		let hostile = Self.file(claiming: Argon2.Parameters(m: 64 * 1024 * 1024, t: 3, p: 4))

		let elapsed = ContinuousClock().measure {
			#expect(throws: ExportEnvelope.Failure.parametersOutOfBounds) {
				try ExportEnvelope.open(hostile, passphrase: "x")
			}
		}
		#expect(elapsed < .seconds(1))
	}

	@Test(arguments: [
		Argon2.Parameters(m: 2 * 1024 * 1024 + 1, t: 3, p: 4),
		Argon2.Parameters(m: 1024, t: 0, p: 1),
		Argon2.Parameters(m: 1024, t: 11, p: 1),
		Argon2.Parameters(m: 1024, t: 1, p: 0),
		Argon2.Parameters(m: 1024, t: 1, p: 17),
		Argon2.Parameters(m: 31, t: 1, p: 4),
		Argon2.Parameters(m: .max, t: .max, p: .max),
	])
	func refusesParametersOutsideTheBoundsInEitherDirection(_ parameters: Argon2.Parameters) {
		#expect(!ExportEnvelope.isWithinBounds(parameters))
		#expect(throws: ExportEnvelope.Failure.parametersOutOfBounds) {
			try ExportEnvelope.open(Self.file(claiming: parameters), passphrase: "x")
		}
		#expect(throws: ExportEnvelope.Failure.parametersOutOfBounds) {
			try ExportEnvelope.seal(Self.zip, passphrase: "x", parameters: parameters)
		}
	}

	@Test func acceptsTheFloorAndEveryEdgeOfTheBounds() {
		#expect(ExportEnvelope.isWithinBounds(Argon2.floor))
		#expect(ExportEnvelope.isWithinBounds(Argon2.Parameters(m: 8, t: 1, p: 1)))
		#expect(ExportEnvelope.isWithinBounds(Argon2.Parameters(m: 128, t: 1, p: 16)))
		#expect(ExportEnvelope.isWithinBounds(Argon2.Parameters(m: 2 * 1024 * 1024, t: 10, p: 16)))
	}
}
