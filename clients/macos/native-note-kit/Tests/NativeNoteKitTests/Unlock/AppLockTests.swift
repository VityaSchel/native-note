import Foundation
import Testing

@testable import NativeNoteKit

struct UnlockParametersTests {
	static let sample = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.floor,
		enclaveKey: Data(repeating: 0x11, count: 8)
	)

	private static func encoded(_ parameters: UnlockParameters) throws -> Data {
		let encoder = PropertyListEncoder()
		encoder.outputFormat = .binary
		return try encoder.encode(parameters)
	}

	@Test func keepsByteFieldsAsRawDataInABinaryPlist() throws {
		let encoded = try Self.encoded(Self.sample)

		#expect(encoded.starts(with: Data("bplist00".utf8)))

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["localSalt"] as? Data == Self.sample.localSalt)
		#expect((plist["argon"] as? [String: Any])?["m"] as? Int == 262_144)
		#expect(try PropertyListDecoder().decode(UnlockParameters.self, from: encoded) == Self.sample)
	}

	@Test func rejectsAFileThatIsNotAPropertyList() {
		#expect(throws: (any Error).self) {
			try PropertyListDecoder().decode(UnlockParameters.self, from: Data("not a property list".utf8))
		}
	}

	@Test func omitsTheEnclaveKeyWhenTheDeviceHasNoSecureHardware() throws {
		var withoutHardware = Self.sample
		withoutHardware.enclaveKey = nil
		let encoded = try Self.encoded(withoutHardware)

		let plist = try #require(
			try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
		)
		#expect(plist["enclaveKey"] == nil)
		#expect(try PropertyListDecoder().decode(UnlockParameters.self, from: encoded) == withoutHardware)
	}
}

struct AppLockTests {
	private func temporaryDirectory() -> URL {
		URL.temporaryDirectory.appending(path: UUID().uuidString)
	}

	@Test func writesPrivatelyAndReadsBack() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(UnlockParametersTests.sample, to: url)

		let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
		let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
		#expect(fileMode?.int16Value == 0o600)
		#expect(directoryMode?.int16Value == 0o700)
		#expect(try AppLock.read(from: url) == UnlockParametersTests.sample)
	}

	@Test func refusesParametersFromAFutureVersion() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var future = UnlockParametersTests.sample
		future.version = 2
		let url = AppLock.currentFile(in: directory)

		try AppLock.write(future, to: url)

		#expect(throws: AppLock.Unreadable.unsupportedVersion(2)) { try AppLock.read(from: url) }
		#expect(AppLock.candidates(in: directory).isEmpty)
	}

	@Test func offersPendingParametersFirstButKeepsTheCurrentOneAsFallback() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParametersTests.sample
		next.localSalt = Data(repeating: 0x99, count: 16)

		try AppLock.write(UnlockParametersTests.sample, to: AppLock.currentFile(in: directory))
		#expect(AppLock.candidates(in: directory).map(\.localSalt) == [UnlockParametersTests.sample.localSalt])

		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))
		#expect(
			AppLock.candidates(in: directory).map(\.localSalt)
				== [next.localSalt, UnlockParametersTests.sample.localSalt]
		)
	}

	@Test func promotingARekeyLeavesExactlyOneFile() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParametersTests.sample
		next.localSalt = Data(repeating: 0x99, count: 16)
		try AppLock.write(UnlockParametersTests.sample, to: AppLock.currentFile(in: directory))
		try AppLock.write(next, to: AppLock.pendingRekeyFile(in: directory))

		try AppLock.promoteRekey(in: directory)

		#expect(AppLock.candidates(in: directory).map(\.localSalt) == [next.localSalt])
		#expect(!FileManager.default.fileExists(atPath: AppLock.pendingRekeyFile(in: directory).path))
		let mode = try FileManager.default.attributesOfItem(atPath: AppLock.currentFile(in: directory).path)[.posixPermissions] as? NSNumber
		#expect(mode?.int16Value == 0o600)
	}

	@Test func reportsNothingWhenTheAppHasNeverBeenSetUp() {
		#expect(AppLock.candidates(in: temporaryDirectory()).isEmpty)
	}
}
