import Foundation
import Testing

@testable import NativeNote

struct MachineChainTests {
	static let argonOut = Data(repeating: 0xa5, count: 32)

	@Test(.enabled(if: MachineKey.isAvailable))
	func survivesReloadingTheKeyFromItsStoredRepresentation() throws {
		let key = try MachineKey()
		let first = try MachineChain.machineId(argonOut: Self.argonOut, rounds: 4, key: key)
		let reloaded = try MachineKey(representation: key.representation)

		#expect(try MachineChain.machineId(argonOut: Self.argonOut, rounds: 4, key: reloaded) == first)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aDifferentPasswordProducesADifferentMachineId() throws {
		let key = try MachineKey()
		let mine = try MachineChain.machineId(argonOut: Self.argonOut, rounds: 4, key: key)
		let theirs = try MachineChain.machineId(argonOut: Data(repeating: 0x5a, count: 32), rounds: 4, key: key)

		#expect(mine != theirs)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func aDifferentDeviceKeyProducesADifferentMachineId() throws {
		let mine = try MachineChain.machineId(argonOut: Self.argonOut, rounds: 4, key: try MachineKey())
		let theirs = try MachineChain.machineId(argonOut: Self.argonOut, rounds: 4, key: try MachineKey())

		#expect(mine != theirs)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func acceptsEveryInputSoAWrongPasswordGetsNoPassFailOracle() throws {
		let key = try MachineKey()
		for byte in UInt8.zero ..< 32 {
			#expect(throws: Never.self) {
				try MachineChain.machineId(argonOut: Data(repeating: byte, count: 32), rounds: 1, key: key)
			}
		}
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func calibrationReturnsAUsableRoundCount() throws {
		let key = try MachineKey()

		let rounds = try MachineChain.calibrateRounds(target: 0.1, probe: 4, key: key)

		#expect((1 ... 100_000).contains(rounds))
		#expect(throws: Never.self) {
			try MachineChain.machineId(argonOut: Self.argonOut, rounds: min(rounds, 8), key: key)
		}
	}

	@Test func roundsAreChainedRatherThanIndependent() throws {
		let seed = KeyDerivation.derive(ikm: Self.argonOut, info: KeyDerivation.chainSeed)

		#expect(MachineChain.scalar(x: seed, index: 0).scalar != MachineChain.scalar(x: seed, index: 1).scalar)
	}
}

struct UnlockParametersTests {
	static let sample = UnlockParameters(
		localSalt: Data(repeating: 0x80, count: 16),
		argon: Argon2.floor,
		rounds: 140,
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
		#expect(plist["rounds"] as? Int == 140)
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
		let url = AppLock.current(in: directory)

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
		let url = AppLock.current(in: directory)

		try AppLock.write(future, to: url)

		#expect(throws: AppLock.Unreadable.unsupportedVersion(2)) { try AppLock.read(from: url) }
		#expect(AppLock.load(in: directory) == nil)
	}

	@Test func prefersPendingParametersSoAnInterruptedRekeyStillOpens() throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		var next = UnlockParametersTests.sample
		next.rounds = 999

		try AppLock.write(UnlockParametersTests.sample, to: AppLock.current(in: directory))
		#expect(AppLock.load(in: directory)?.rounds == 140)

		try AppLock.write(next, to: AppLock.pendingRekey(in: directory))
		#expect(AppLock.load(in: directory)?.rounds == 999)
	}

	@Test func reportsNothingWhenTheAppHasNeverBeenSetUp() {
		#expect(AppLock.load(in: temporaryDirectory()) == nil)
	}
}
