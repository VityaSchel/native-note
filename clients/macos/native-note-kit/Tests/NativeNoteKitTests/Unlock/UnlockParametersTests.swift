import Foundation
import Testing

@testable import NativeNoteKit

struct UnlockParametersTests {
	private static func encoded(_ parameters: UnlockParameters) throws -> Data {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = AppLock.currentFile(in: directory)
		try AppLock.write(parameters, to: file)
		return try Data(contentsOf: file)
	}

	@Test func keepsByteFieldsAsRawDataInABinaryPlist() throws {
		let encoded = try Self.encoded(.sample)

		#expect(encoded.starts(with: Data("bplist00".utf8)))

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["localSalt"] as? Data == UnlockParameters.sample.localSalt)
		#expect((plist["argon"] as? [String: Any])?["m"] as? Int == 262_144)
		#expect(try PropertyListDecoder().decode(UnlockParameters.self, from: encoded) == .sample)
	}

	@Test func rejectsAFileThatIsNotAPropertyList() {
		#expect(throws: (any Error).self) {
			try PropertyListDecoder().decode(UnlockParameters.self, from: Data("not a property list".utf8))
		}
	}

	@Test func omitsTheEnclaveKeyWhenTheDeviceHasNoSecureHardware() throws {
		var withoutHardware = UnlockParameters.sample
		withoutHardware.enclaveKey = nil
		let encoded = try Self.encoded(withoutHardware)

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["enclaveKey"] == nil)
		#expect(try PropertyListDecoder().decode(UnlockParameters.self, from: encoded) == withoutHardware)
	}
}
