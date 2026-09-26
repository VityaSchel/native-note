import CryptoKit
import Foundation
import Testing

@testable import NativeNoteKit

@Suite(.serialized)
struct MachineKeyTests {
	@Test(.enabled(if: MachineKey.isAvailable))
	func isStableForOneDeviceKey() throws {
		let key = try MachineKey()

		#expect(try key.machineId() == key.machineId())
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func survivesReloadingTheKeyFromItsStoredRepresentation() throws {
		let key = try MachineKey()
		let before = try key.machineId()
		let reloaded = try MachineKey(representation: key.representation)

		#expect(try reloaded.machineId() == before)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func differsPerDeviceKey() throws {
		#expect(try MachineKey().machineId() != MachineKey().machineId())
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func doesNotDependOnThePassword() throws {
		let key = try MachineKey()
		let localSalt = Data(repeating: 0x80, count: 16)
		let machineId = try key.machineId()

		let mine = KeyDerivation.localDbKey(argonOut: SymmetricKey(data: Data(repeating: 0xa5, count: 32)), machineId: machineId, localSalt: localSalt)
		let theirs = KeyDerivation.localDbKey(argonOut: SymmetricKey(data: Data(repeating: 0x5a, count: 32)), machineId: machineId, localSalt: localSalt)

		#expect(mine != theirs)
	}

	@Test(.enabled(if: MachineKey.isAvailable))
	func isHKDFOverTheKeyAgreeingWithItself() throws {
		let key = try MachineKey()
		let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: key.representation)
		let secret = try enclave.sharedSecretFromKeyAgreement(with: enclave.publicKey).withUnsafeBytes { Data($0) }

		let expected = HKDF<SHA256>.deriveKey(
			inputKeyMaterial: SymmetricKey(data: secret),
			salt: Data(),
			info: Data("native-note/machine-id/v1".utf8),
			outputByteCount: 32
		)

		#expect(try key.machineId() == expected)
	}
}
